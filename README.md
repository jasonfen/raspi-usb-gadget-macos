# Raspberry Pi USB gadget internet sharing from MacOS 26 Public Beta

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

## Retest with dr_mode=peripheral: byte-identical failure (2026-09-01)

The `config.txt` fix took, and it changed nothing.

**Proof the fix applied** — four lines present in the otg run are absent in the
peripheral run. They are the dwc2 *host controller* registration, which peripheral-only
mode does not perform:

```
- dwc2 3f980000.usb: DWC OTG Controller
- dwc2 3f980000.usb: new USB bus registered, assigned bus number 1
- dwc2 3f980000.usb: irq 51, io mem 0x3f980000
- usb usb1: Manufacturer: Linux 6.18.39+rpt-rpi-v8 dwc2_hsotg
```

(The in-payload `find /proc/device-tree -name dr_mode` check returned nothing, but that
is a bug in the check, not a finding: `/proc/device-tree` is a symlink and `find` will
not descend into one without `-L`.)

**The failure is unchanged.** `rx_packets` reaches 1 at t=10s and stays there for the
next 350s, while `tx_packets` climbs to 284. Identical to the otg run.

**ECM MAC negotiation is fine**, which kills the descriptor theory outright:

```
Pi dmesg : g_ether gadget.0: HOST MAC 8e:d3:84:da:46:09
Mac      : en7 hardware address 8e:d3:84:da:46:09   (and IOKit IOMACAddress agrees)
```

macOS adopts the advertised host MAC correctly. Whatever is broken, it is not the
descriptor or the MAC.

### What both sides now agree on

Exactly one frame, 76 bytes, crosses at t<10s. Then the OUT direction stops dead and
never recovers, in either mode, across eight sessions.

The most economical reading: the gadget's OUT endpoint takes one packet and never
re-arms, so the host's OUT transfers stop completing, its queue backs up, and `Opkts`
freezes at 161. That makes the frozen host counter a *consequence* of the device-side
stall rather than an independent macOS fault — and it means the earlier "macOS never
transmits" framing had the causality backwards.

Not yet collected, and the obvious next step: `/sys/kernel/debug/dwc2/` endpoint state
and `/proc/interrupts` IRQ 51 counts across the wedge. If the dwc2 interrupt count
keeps climbing while `rx_packets` is flat, this is a software requeue bug in `u_ether`;
if it stalls, the controller itself has halted the endpoint.

Evidence: `diag3-peripheral.txt`.

## ROOT CAUSE: the Mac never puts a frame on the wire (2026-09-01)

`en7` transmits nothing at all. Not "the packets are queued and lost somewhere" —
nothing is ever emitted.

tcpdump on `en7`, 10s, while actively generating traffic (broadcast ping, unicast
ping, a ping to an unresolved address to force a fresh ARP):

```
5 packets captured
19:08:25 ca:47:db:5e:15:43 > ff:ff:ff:ff:ff:ff  ARP Request who-has 10.42.0.1 tell 10.12.194.1
19:08:27 ca:47:db:5e:15:43 > ff:ff:ff:ff:ff:ff  ARP Request who-has 192.168.137.1 tell 10.12.194.1
19:08:28 ca:47:db:5e:15:43 > ff:ff:ff:ff:ff:ff  ARP Request who-has 192.168.2.1 tell 10.12.194.1
...
outbound frames from this Mac: 0
```

All five are inbound from the Pi. Zero outbound — including the `arp-responder.py`
BPF injections, which logged 111 replies sent over the same window. BPF writes do not
reach the wire either.

Paired counters over 400s (`hostside.txt` + `diag2.txt`):

| | host (en7) | device (usb0) |
|---|---|---|
| Pi -> Mac | Ipkts 143 -> 421 | tx climbing |
| Mac -> Pi | Opkts **161, flat, Oerrs 0** | rx ~0 |

A broadcast ping — which needs no ARP resolution and must hit the wire — moves `Opkts`
by exactly 0.

### Instrument control (run this before trusting any capture)

"en7 sends nothing" is only meaningful if tcpdump on this Mac can see outbound frames
at all. Same capture, same script, against Wi-Fi as a control:

| interface | frames | outbound from our own MAC |
|---|---|---|
| `en0` (control) | 60 | **29** |
| `en7` (gadget) | 3 | **0** |

BPF outbound visibility works here. The zero on `en7` is real.

Evidence: `bpf_en0.cap`, `bpf_en7.cap`.

### Not a null MAC (theory tried and dropped)

`en7` was once observed with `ether 02:00:00:00:00:00` while IOKit held the correct
`IOMACAddress = 8e:d3:84:da:46:09`, which looked like a stuck null address preventing
transmission. It is not: on a later check `en7` carried the correct MAC and TX was
still completely dead. The all-zero read was a transient initialisation state.

### The wedge happens after enumeration, not instead of it

Worth keeping in view: the device received **exactly 1 packet, 76 bytes, within the
first 10s**, then nothing for 350s. The path carries a frame once and then stops. This
is a wedge shortly after enumeration, not a link that never came up.

### The likely mechanism: the BSD interface never got a MAC

```
IOKit  "IOMACAddress" = <8ed384da4609>     # correct, read from the descriptor
en7    ether 02:00:00:00:00:00             # what the BSD/Skywalk interface actually has
```

IOKit parsed the address fine; it never propagated into the network interface. An
interface with an all-zero source MAC cannot transmit, which is exactly what the
capture shows.

The control plane is failing the same way. Both of these are `ETIMEDOUT` on a control
operation against the same dext:

```
BIOCPROMISC: Operation timed out          # tcpdump, this session
mis_bridge_add_int_if: ... err 60         # InternetSharing BRDGADD, earlier
```

So the Internet Sharing bridge failure is not a separate bug to work around — it is
the same fault. The stack is `AppleUSBCDCCompositeDevice` -> `AppleUserECM` (DriverKit)
-> `IOSkywalkLegacyEthernet` -> `IOSkywalkNetworkBSDClient`.

This also explains the host-dependence in #19. Linux's `cdc_ether` tolerates a MAC it
cannot use and substitutes a random one. `AppleUserECM` appears to come up
half-initialised instead: RX armed, TX never.

### The packaging bugs are probably the trigger, not a footnote

macOS is visibly choking on the descriptor `g_ether.conf` ships:

```
ioreg: "iSerialNumber" = 3      # a serial string is declared at index 3
ioreg: (no "USB Serial Number" property)   # ...and reads back empty
```

Combined with no `host_addr`/`dev_addr`, so the advertised MAC is random every boot.
Next test is to set all three in `g_ether.conf` and see whether `en7` comes up with a
real MAC and a live TX path.

### Not the dr_mode defect

The `dtoverlay=dwc2` misconfiguration documented below is real and worth keeping fixed,
but it is not the cause: the Mac emits nothing regardless of what mode the Pi's
controller is in.

## The controller was never in peripheral mode (found 2026-09-01)

Every measurement below was taken with dwc2 in **otg** mode, not peripheral. In
`config.txt`, the `rpi-usb-gadget` install appended:

```
[pi5]
dtoverlay=spi0-2cs
#dtoverlay=disable-wifidtoverlay=dwc2,dr_mode=peripheral
```

Two independent failures in one line:

1. **It is inside a comment.** The file had no trailing newline, so the append glued
   `dtoverlay=dwc2,dr_mode=peripheral` onto `#dtoverlay=disable-wifi`. Confirmed by
   hexdump: a single `\n` at EOF, none before the appended text.
2. **It is under `[pi5]`.** A Zero 2 W is `[pi02]`. Conditional filters persist until
   the next filter, so an append at EOF lands in whatever section happens to be last.

The only dwc2 line that actually applied was `dtoverlay=dwc2` under `[all]`, which
defaults `dr_mode` to **otg**. dmesg agrees: `DWC OTG Controller`, and nothing
declaring peripheral mode. It still enumerates, because ID floats to B-device — which
is exactly why this went unnoticed for the whole investigation.

Fixed on the card: `[all]` now carries `dtoverlay=dwc2,dr_mode=peripheral`, the
comment is restored, and the file ends with a newline. Backup in
`boot-backup/config.txt.pre-drmode-fix`.

**This is a third upstream packaging bug**, and worse than the other two: the installer
appends to `config.txt` without a newline guard and without forcing an `[all]` filter.
Any image whose `config.txt` ends in a comment or a model filter gets a silently
inert gadget.

### Everything below is PENDING RETEST

> The host->device analysis that follows was measured against a controller running the
> OTG state machine instead of hard peripheral mode. The counters are real, but the
> conclusion drawn from them — that macOS queues OUT transfers it never delivers — now
> rests on an untested premise. Same class of error as the `Opkts` trap: the
> instrument was fine, the setup underneath it was not.
>
> The upstream comments on #27 and PR #31 were filed under this premise and need a
> correction once the retest lands.

## Superseded: the host->device path silently drops everything

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
