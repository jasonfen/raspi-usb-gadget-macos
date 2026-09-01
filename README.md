# Raspberry Pi USB gadget — internet sharing from this Mac

Pi runs [rpi-usb-gadget](https://github.com/raspberrypi/rpi-usb-gadget) (PiOS trixie).
The USB cable is the Pi's **only** connection — it has no upstream of its own.

## Why not just use macOS Internet Sharing

It's broken on this machine. The daemon fails to add the gadget interface to its
bridge:

```
ioctl(..., SIOCSDRVSPEC) BRDGADD: failed Operation timed out
mis_bridge_add_int_if: add_bridge_member, err 60   # ETIMEDOUT
```

Without the bridge there's no address, no NAT, no DHCP. `launchctl kickstart` can't
restart the daemon either — SIP blocks it (`150: Operation not permitted`). Only a
reboot clears a wedged `InternetSharing` process.

## How this works instead

The Pi's `rpi-usb-gadget-ics.service` ARP-probes for a known ICS gateway and flips
itself to client mode when it finds one. On macOS that address is **192.168.2.1**.
So we present that by hand and skip Internet Sharing entirely:

| Piece | What it does |
|---|---|
| `192.168.2.1/24` on the gadget interface | the address the Pi's watcher probes for |
| `bootpd` scoped to that interface | leases `192.168.2.2–20`, router `.1`, DNS `1.1.1.1` |
| `net.inet.ip.forwarding=1` | route between the Pi and Wi-Fi |
| pf anchor `pi-nat` | `nat on en0 from 192.168.2.0/24 -> (en0)` |

No bridge anywhere, so the `BRDGADD` bug never comes into play.

Pi modes, for reference:
- **shared** (default) — Pi takes `10.12.194.1/28`, runs its own DHCP, NATs to *its*
  upstream. Useless here: the Pi has no upstream.
- **client** — Pi DHCPs from our gateway. This is what we want.

## ROOT CAUSE (confirmed): the host->device path silently drops everything

Full 6-minute capture, counters from both sides of one session:

| | host (macOS) | device (usb0) |
|---|---|---|
| host -> Pi | Opkts 161, Obytes 44858, Oerrs 0 | rx_packets **1**, rx_bytes 76 |
| Pi -> host | Ipkts 346 | tx_packets 291 |

Device RX reports `errors 0, dropped 0, missed 0`. The one packet arrived in the
first 10s, then nothing for 350s. Host Opkts stopped at exactly 161 in six separate
sessions.

Both sides report success. Neither kernel logs anything. The OUT path discards data
silently somewhere in between.

### What this is NOT

**Not the NO-CARRIER failure in #29.** `carrier=1` on every sample; final state is
`usb0 <BROADCAST,MULTICAST,UP,LOWER_UP> state UP` with `10.12.194.1/28`. An earlier
reading here said otherwise; it was taken before the interface finished coming up.

**Not PR #31's logged signature.** dmesg is byte identical at t=60/120/180/240/300/360.
Nothing after `bound driver g_ether`. No `ep_stop_xfr`, no `txfifo_flush`, no timeouts.

**Not a DHCP timing race** (which is what #27 assumes). DHCP cannot complete when the
host's packets never arrive.

### Best guess

#19's reporter had the same Pi work correctly against a NixOS host, so the weight sits
on macOS never actually submitting or completing the OUT transfers while counting them
as sent. Not proven from counters on either end.

Reported upstream:
[#27 comment](https://github.com/raspberrypi/rpi-usb-gadget/issues/27#issuecomment-5500820194),
[PR #31 comment](https://github.com/raspberrypi/rpi-usb-gadget/pull/31#issuecomment-5500820418).

### Do not trust Opkts

`Opkts` counts packets the host driver queued, not packets delivered. It read 161 while
the device received 1. Any test that treats it as proof of transmission is worthless
here, including the "TX budget" reasoning further down this file.

### Packaging bugs found

`/usr/lib/modprobe.d/g_ether.conf`:

```
options g_ether idVendor=0x2E8A ... iProduct="Raspberry Pi USB Gadget" iSerialNumber=
```

`iSerialNumber` is empty, but `/proc/cpuinfo` on the running board *does* have
`Serial: 000000001bda2cd5` (devicetree agrees). So the file was stamped blank at image
build time, not by a failing awk at runtime. Matters for PR #31, which derives MACs
from that same field: already-shipped images need re-stamping, not just an install-time
guard.

No `host_addr`/`dev_addr` either, so `u_ether` randomises the MAC every module load.
Seven distinct gadget MACs across seven boots.

### Getting data off a Pi with no shell

USB was the only path in, and it was broken, so device-side data came from a one-shot
systemd service written to the FAT boot partition from macOS, launched via
`systemd.run=/boot/firmware/firstrun.sh systemd.unit=kernel-command-line.target` in
`cmdline.txt`. It sampled `/sys/class/net/usb0/statistics` every 10s, snapshotted dmesg
every 60s, wrote results back to the boot partition, and deleted itself.

**`systemd.unit=kernel-command-line.target` is required.** Without it `systemd.run`
generates a unit that never executes. Write incrementally with `sync`: an early unplug
loses everything buffered.

## Earlier theory: the driver transmits exactly 161 packets, then stops

> **SUPERSEDED.** Kept as a record of what was ruled out. The 161 figure is real but
> it is a host-side queue count, not delivery. The device receives 1 packet either way.
> The NCM suggestion below is also dead: `g_ncm` does not exist in this kernel (only
> `usb_f_ncm`, the configfs function), so `modules-load=dwc2,g_ncm` cannot work.

`com.apple.DriverKit.AppleUserECM` stops transmitting after **exactly 161 packets**
per USB enumeration. Measured three times across three independent replugs:

| session | Opkts at wedge | Obytes | Oerrs |
|---|---|---|---|
| 1 | 161 | 40372 | 0 |
| 2 | 161 | — | 0 |
| 3 (started at 114) | 161 | 39990 | 0 |

`Obytes` differs while `Opkts` is identical, so the cap is on **packet count**, not
bytes. When wedged: link still reports `UP,RUNNING` and `status: active`, RX keeps
working indefinitely, `Oerrs=0`, the dext is alive with near-zero CPU, and nothing is
logged. It fails completely silently.

Nothing fixes it: interface bounce, disabling TSO/offloads, MTU change, re-adding
addresses. Only a replug resets the counter — buying another 161 packets.

**Everything else in this repo is downstream of this.** The Internet Sharing
`BRDGADD` timeout is a symptom (bridge-add needs to transmit). So is every unanswered
ARP, every ping timeout, and every "closed" port.

### Diagnostic trap

A wedged TX looks identical to a dozen other faults, and it silently voids any test
that needs to send. Always run this control first:

```sh
A=$(netstat -I en7 -b | awk 'NR==2{print $8}')
ping -c3 192.168.2.99 >/dev/null 2>&1; sleep 2
B=$(netstat -I en7 -b | awk 'NR==2{print $8}')
[ "$B" -gt "$A" ] && echo "TX alive" || echo "TX WEDGED at $B -- all send-tests are void"
```

Tests invalidated by not doing this: BPF-injection-is-blocked (false — injection works
fine on a fresh interface, all three methods transmit), and macOS-won't-ARP-reply-
off-subnet (unproven — every zero-reply capture was taken while TX was dead).

### Second, independent problem

With TX alive, ~47 real ARP replies reached the Pi over ~2 minutes and it still did
not leave shared mode. So the watcher needs more than an ARP reply, or is stuck.
That needs Pi-side logs: `journalctl -u rpi-usb-gadget-ics`.

### Where this leaves the USB gadget path

Dead on macOS 27.0 beta. 161 packets per replug is unusable. Use the SD card instead:
configure the Zero 2 W's built-in Wi-Fi, or switch the gadget from ECM to NCM so a
different macOS driver handles it.

A Mac-side USB ethernet dongle does NOT help — the Zero 2 W has no ethernet port and
its single OTG port is the link to the Mac.

## The ARP theory (unproven, kept for reference)

> **SUPERSEDED.** Every zero-reply capture behind this was taken while nothing was
> being delivered, so it proves nothing about macOS ARP semantics. The userspace
> responder does emit valid replies; they just never arrive.

The Pi's ICS watcher probes, every ~4s:

```
Request who-has 192.168.2.1 tell 10.12.194.1
```

The sender (`10.12.194.1`, the Pi's shared-mode address) is on a **different
subnet** than the target. macOS/BSD refuses to answer such a request; Linux and
Windows both do. So the Pi's detection works on those hosts and silently fails here,
and the Pi stays in shared mode forever.

Things that do NOT fix it:
- adding a `10.12.194.2/28` alias so the sender is on-link — macOS still scopes ARP
  replies per address-subnet
- `arp -s 192.168.2.1 <mac> pub` — rejected, "proxy entry exists for non 802 device",
  because the address is already ours
- `net.link.ether.inet.proxyall=1` — untested on purpose. It is global, and on a
  corporate LAN it can make this Mac answer ARP for addresses it shouldn't. Don't.

What works: `arp-responder.py` opens a BPF device and emits the reply itself,
bypassing the kernel's subnet check. Pure stdlib. Confirmed sending replies the Pi
accepts at layer 2.

**Open issue:** the Pi receives the replies but does not flip to client mode when it
has already booted into shared mode. The responder must be running *before* the Pi's
first probe — hence `full-setup.sh`, which is run right after a replug.

## Usage

Replug the Pi, then immediately:

```sh
sudo ./full-setup.sh      # waits for the interface, configures everything,
                          # starts the ARP responder before the Pi's first probe
```

That is the whole flow. The others are diagnostics:

```sh
sudo ./capture.sh 20      # what is actually on the wire (start here when stuck)
sudo ./check-gadget.sh    # is the gadget enumerated with real interfaces?
sudo ./verify-pi.sh       # lease / ARP / NAT state
sudo ./run-responder.sh   # responder only, against an already-configured link
./gadget-snapshot.sh      # one-shot USB state, for before/after comparisons
```

Scripts share the detected interface name via `.gadget-if`.

`ics-emulate.sh` and `fresh-start.sh` are superseded by `full-setup.sh`;
`unwedge-tx.sh` and `proxy-arp.sh` are dead ends kept only as a record of what failed.

## Gotchas

**Nothing here survives a reboot.** `ip.forwarding` resets and pf won't auto-load
`/etc/pf-pi.conf`. Re-run `ics-emulate.sh`. (`/etc/bootpd.plist` does persist.)

**The interface name is not stable.** It was `en7`, but re-enumeration can change it.
The scripts auto-detect via `networksetup -listallhardwareports`.

**DHCP is scoped to the gadget interface only.** This Mac sits on a real corporate LAN
(`10.108.x`). A DHCP server loose on `en0` would hand out bogus leases to other people.
Don't widen `dhcp_enabled` in `/etc/bootpd.plist`.

**If an address gets applied and vanishes within ~1s**, a live `InternetSharing`
process is stripping it. Check `pgrep -x InternetSharing`; SIP means a reboot is the
only reliable fix. `ics-emulate.sh` polls 5× and aborts rather than continuing on a
stripped address.

**If `IOUSBHostInterface nubs` is 0**, the gadget enumerated without composing its USB
functions — usually the Mac read its descriptors before the Pi finished booting.
Replug the cable; reboot the Pi if that doesn't fix it. No host-side config can help.

**Count nubs in the `IOService` plane, not `IOUSB`.** `ioreg -p IOUSB` does not include
interface nubs and always reports 0, which looks exactly like a failed gadget. Use:

```sh
ioreg -p IOService -w0 -r -n "Raspberry Pi USB Gadget" | grep -c IOUSBHostInterface
```

A healthy device shows the full chain — `CDC Ethernet Control Model (ECM)` ->
`AppleUserECM` -> `en7`. The real ground truth is simply whether the BSD interface
exists; trust that over any registry count.

**The Pi takes ~57s after replug to appear on the bus.** Snapshotting sooner reports
"NOT ON BUS" and means nothing. Use `watch-gadget.sh`, which polls instead of guessing.

**macOS has no `timeout` command.** Not in base, not via coreutils here. Any
`timeout N cmd` silently fails with "command not found" and produces empty output that
reads exactly like a negative result. This burned two `tcpdump` runs and every `dns-sd`
sweep in this repo. Use background + kill instead:

```sh
cmd > out 2>&1 & P=$!; sleep N; kill $P 2>/dev/null; wait $P 2>/dev/null
```

Never let a diagnostic's failure to run look like a finding — `capture.sh` now checks
for tcpdump errors explicitly and distinguishes them from a silent wire.

## Diagnosing

```sh
# is the TX path alive? Opkts should climb, not sit frozen
netstat -I "$(cat .gadget-if)" -b | awk 'NR==2{print "Ipkts="$5" Opkts="$8}'

# is an address actually applied? SystemConfiguration lies — trust ifconfig
ifconfig "$(cat .gadget-if)" | grep "inet "
networksetup -getinfo "Raspberry Pi USB Gadget"

# sharing daemon complaints
log show --predicate 'process == "InternetSharing"' --last 10m --style syslog | grep -iE "BRDG|err"
```

An interface with no IPv4 address shows frozen `Opkts` and looks exactly like a dead
driver. Check the address before concluding the hardware is broken.

## Reverting

```sh
sudo pfctl -f /etc/pf.conf                 # drop the NAT ruleset
sudo sysctl -w net.inet.ip.forwarding=0
sudo cp backup/bootpd.plist.pre-ics /etc/bootpd.plist
sudo networksetup -setdhcp "Raspberry Pi USB Gadget"
```

## Context

macOS 27.0 beta (26A5421a). Sharing upstream is Wi-Fi `en0`.
