# A Raspberry Pi USB ethernet gadget cannot get internet from macOS 27 beta

**Short version:** plug a Raspberry Pi running USB ethernet gadget mode into a Mac on
macOS 27.0 beta and the link comes up, gets an IP, and then transmits nothing. Not
slowly. Nothing. macOS' CDC ECM driver reports 161 packets sent; the Pi's USB
controller registers exactly **one** inbound packet, ever. No error, no log line, on either side.

This is a macOS defect. Nothing on the Pi is at fault: not Raspberry Pi OS, not
`g_ether`, not dwc2, not `rpi-usb-gadget`. No amount of host-side configuration
fixes it. Filed with Apple as
[FB24614121](https://feedbackassistant.apple.com/feedback/24614121).

If you are here because your Pi won't take a DHCP lease from your Mac over USB: skip
to [What to do instead](#what-to-do-instead).

---

## What you actually see

| | |
|---|---|
| Gadget enumerates | yes, `Raspberry Pi USB Gadget` in System Information, `en7` appears |
| `ifconfig` | interface `UP,RUNNING`, `status: active`, carrier present |
| Ping the Pi | 100% loss |
| `netstat -I en7 -b` | `Opkts` climbs to **161**, then freezes forever. `Oerrs 0` |
| Internet Sharing | fails with `BRDGADD: Operation timed out` |
| Console / dmesg | nothing, on either machine |
| Replug | resets the counter, buys another 161 phantom packets, changes nothing |

Every one of those looks like a different bug. They are all the same one.

## The measurement that settles it

The trap in this whole investigation is that `Opkts` counts packets the *host driver
queued*, not packets that reached the wire. It read 161 while the device had received
1. Any test that treats it as proof of transmission is worthless here.

So the deciding evidence came from a counter neither side's networking stack controls:
the **dwc2 USB controller interrupt count** on the Pi, sampled alongside the packet
counters over a 360-second run.

```
t(s)   rx_packets  tx_packets  dwc2_irq     note
10     1           20          128(+26)     rx +1
60     1           58          166(+8)      rx flat 50s
180    1           149         257(+8)      rx flat 170s
360    1           284         392(+7)      rx flat 350s
```

Across all 36 ten-second intervals, **the dwc2 interrupt delta exactly equals the
`tx_packets` delta: 36 matches, no exceptions.** Every interrupt the controller
raised is accounted for by an outbound completion. Not one is attributable to an
inbound transfer.

The controller is alive and interrupting normally for the full 360 seconds, and it
never sees data arrive from the host. Device-side error counters are all zero:
`rx_errors 0, rx_dropped 0, rx_fifo_errors 0, rx_crc_errors 0, rx_missed_errors 0`.

Confirmed independently on the Mac with a packet capture, against a control:

| interface | frames captured | outbound from our own MAC |
|---|---|---|
| `en0` (Wi-Fi, control) | 60 | **29** |
| `en7` (gadget) | 3 | **0** |

BPF outbound visibility works fine on this Mac. The zero on `en7` is real. Even a
broadcast ping, which needs no ARP resolution and must hit the wire, moves `Opkts`
by exactly zero.

**Conclusion: the packets never leave the Mac.**

## Where the fault sits

```
AppleUSBCDCCompositeDevice → AppleUserECM (DriverKit) → IOSkywalkLegacyEthernet → BSD en7
                                    ↑
                              fails here
```

The best available explanation, inference from the failure's shape rather than from
Apple's source, is a **leaked Skywalk TX packet pool**. `AppleUserECM` is a DriverKit dext on
`IOSkywalkFamily`, which allocates a fixed-size TX packet pool at attach. If sent
packets are never returned to the pool, it runs dry at a fixed count and the interface
can never transmit again until a replug builds a fresh dext.

| observation | consistent? |
|---|---|
| halts at exactly 161 across nine independent enumerations | yes, fixed-size resource |
| identical with `dr_mode=otg` and `dr_mode=peripheral` | yes, host-side |
| identical with and without routes configured | yes |
| RX unaffected and continuous | yes, separate pool |
| `Oerrs=0`, nothing logged anywhere | yes, allocation failure is not an error |
| only a replug clears it | yes, new dext, new pool |
| Internet Sharing `BRDGADD` and `BIOCPROMISC` both `ETIMEDOUT` | yes, control ops blocking on an exhausted dext |

That last row matters: the Internet Sharing bridge failure is not a separate bug to
work around. It is this bug, seen from the control plane.

## Ruled out

Recorded so nobody re-runs them. Each was tested and killed:

- **`dr_mode`**: the controller really was in `otg` instead of `peripheral` for most
  of this investigation (a genuine `config.txt` bug, see below). Fixed it. Failure is
  byte-identical.
- **A null source MAC**: `en7` was once seen with `02:00:00:00:00:00`, which looked
  decisive. It is a transient init state; with the correct MAC applied, TX is still dead.
- **Descriptor / MAC negotiation**: ECM host-MAC negotiation completes correctly and
  macOS adopts the advertised address. Verified against `ioreg`.
- **Missing or wrong routes**: on-link routes present and correct, `route -n get`
  resolves to the gadget interface. Still 161.
- **A DHCP timing race**: DHCP cannot complete when the host's packets never arrive.
- **NO-CARRIER on the Pi**: `carrier=1` on every sample.
- **Interface bounce, MTU changes, disabling TSO/offloads, re-adding addresses**: no effect.
- **A USB-ethernet dongle on the Mac**: irrelevant. The Zero 2 W has no ethernet port
  and its single OTG port *is* the link.
- **A resolved `arp -an` entry**: looks like a successful round trip, isn't. macOS
  caches the sender address from the Pi's inbound ARP requests without transmitting
  anything. Ping is the honest test.

## What to do instead

Ranked by how likely they are to actually work. Only the first is confirmed.

**1. Use a different host for the USB link. (Confirmed working.)**
Linux hosts drive the same gadget correctly. This is the same failure pattern
[rpi-usb-gadget#19](https://github.com/raspberrypi/rpi-usb-gadget/issues/19) reports
working against a NixOS host. If you have any non-Mac machine, use it.

**2. Switch the gadget off CDC ECM, so a different macOS driver handles it. (Untested.)**
The bug is in `AppleUserECM` specifically. NCM binds a different macOS driver.
Note: the current PiOS trixie kernel has no `g_ncm`, only `usb_f_ncm`, the configfs
function. So `modules-load=dwc2,g_ncm` cannot work; it has to be built through
configfs.

**3. Bluetooth PAN instead of USB. (Untested.)**
bluez on the Pi side, macOS Bluetooth sharing on the other. Its own adventure to set
up, but it does not touch the broken code path.

**Not a workaround: replugging.** The 161-packet allowance is phantom. The device
receives one packet per enumeration regardless, so there is no window in which the link
works.

## Two real upstream bugs found along the way

Neither causes the above. Both are genuine, and both survive into shipped images
rather than being install-time-only mistakes.

**`config.txt` append corruption:
[rpi-usb-gadget#32](https://github.com/raspberrypi/rpi-usb-gadget/issues/32).**
The installer appends to `config.txt` with no newline guard and no `[all]` filter. On
this image the file had no trailing newline, so the append fused onto the previous
line, inside a comment:

```
#dtoverlay=disable-wifidtoverlay=dwc2,dr_mode=peripheral
```

…and landed under a `[pi5]` filter, on a Zero 2 W (`[pi02]`). The setting was inert.
It goes unnoticed because a bare `dtoverlay=dwc2` under `[all]`, which many gadget
images already carry, still brings dwc2 up, defaulting to `otg`, where the floating ID pin
settles into device mode anyway. The gadget enumerates and looks healthy. Worse: the
uninstall `sed` is anchored to the whole line, so once fused the line cannot be
deduped, disabled, or removed.

**Blank `iSerialNumber`, no `host_addr`/`dev_addr`.**
`/usr/lib/modprobe.d/g_ether.conf` ships with an empty serial, while `/proc/cpuinfo` on
the running board has a real one, so it was stamped blank at image build time (likely
a chroot, where `/proc/cpuinfo` is the build host's), not by a failing lookup at
runtime. Already-shipped images need re-stamping, not just an install-time guard. With
no `host_addr`/`dev_addr` either, `u_ether` randomises the gadget MAC on every module
load. Seven distinct MACs across seven boots here.

Earlier comments on
[rpi-usb-gadget#27](https://github.com/raspberrypi/rpi-usb-gadget/issues/27) and
[PR #31](https://github.com/raspberrypi/rpi-usb-gadget/pull/31) blamed those
maintainers for the TX failure. They were
[withdrawn](https://github.com/raspberrypi/rpi-usb-gadget/issues/27#issuecomment-5502370421)
once the fault was traced to macOS.

## Check whether you have this bug

Run this on the Mac with the Pi plugged in. It is the control that voids every other
test, and it takes five seconds:

```sh
IF=en7   # or whatever your gadget interface is
A=$(netstat -I $IF -b | awk 'NR==2{print $8}')
ping -c3 192.168.2.99 >/dev/null 2>&1; sleep 2
B=$(netstat -I $IF -b | awk 'NR==2{print $8}')
[ "$B" -gt "$A" ] && echo "TX alive" || echo "TX WEDGED at $B -- all send-tests are void"
```

If it says WEDGED, every subsequent diagnostic that needs to transmit will produce a
false negative. Two conclusions in this repo's history were wrong for exactly that
reason.

## What is in this repo

The host-side workaround that *would* work if TX were alive. It replaces macOS
Internet Sharing entirely, avoiding the `BRDGADD` bug, by hand-configuring the gateway
address the Pi's ICS watcher probes for:

```sh
sudo ./full-setup.sh    # run immediately after a replug
```

It applies `192.168.2.1/24` to the gadget interface, scopes `bootpd` to it for DHCP,
enables IP forwarding, loads a pf NAT anchor, and starts a userspace ARP responder
before the Pi's first probe. No bridge anywhere. This is correct and complete, and it
still cannot deliver a packet, because of the bug above.

The diagnostics, roughly in the order they earned their keep:

| script | what it answers |
|---|---|
| `bpf-control.sh` | **run first.** Can tcpdump see outbound frames on this Mac at all? |
| `tx-probe.sh` | Does anything leave the interface? Separates dead TX from a lying `Opkts` |
| `addr-and-route.sh` | Apply addresses, prove on-link routes exist, drive traffic |
| `host-watch.sh` | 400s host-side counter log, pairs with the Pi's `diag4.txt` |
| `capture.sh 20` | What is actually on the wire |
| `check-gadget.sh` | Is the gadget enumerated with real USB interfaces? |
| `firstrun.sh` | Device-side sampler for a Pi with no working shell (see below) |

Raw evidence: `diag*.txt` (device side), `hostside.txt`, `bpf_en0.cap` / `bpf_en7.cap`
(the capture control pair), `responder.log`, `apple-feedback.md` (the Apple report and
its evidence list).

The full chronological notebook, including every theory that turned out to be wrong and
why, is in **[`INVESTIGATION.md`](INVESTIGATION.md)**.

## Getting data off a headless Pi with no working link

Useful well beyond this bug. USB was the only path in and it was broken, so device-side
data came from a one-shot systemd service written to the FAT boot partition from macOS
and launched from `cmdline.txt`:

```
systemd.run=/boot/firmware/firstrun.sh systemd.unit=kernel-command-line.target
```

It sampled `/sys/class/net/usb0/statistics` every 10s, snapshotted dmesg every 60s,
wrote results back to the boot partition, and deleted itself.

`systemd.unit=kernel-command-line.target` is **required**. Without it `systemd.run`
generates a unit that never executes. Write incrementally with `sync`, or an early
unplug loses everything buffered.

## Environment

| | |
|---|---|
| Host | Apple Silicon Mac, macOS 27.0 beta (build 26A5421a), upstream Wi-Fi `en0` |
| Device | Pi Zero 2 W, Raspberry Pi OS trixie, kernel 6.18.39+rpt-rpi-v8 |
| Gadget | [`rpi-usb-gadget`](https://github.com/raspberrypi/rpi-usb-gadget), `g_ether` → CDC ECM |

Not tested on macOS 26 or earlier, on Intel Macs, or on other Pi models. If you have
this working, or failing, on any of those, that is worth knowing.
