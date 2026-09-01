# Apple Feedback Assistant — draft

**Area:** macOS → Networking (also relevant: USB, DriverKit)
**Type:** Incorrect/Unexpected Behavior
**Reproducibility:** Always (10/10 attempts, ten independent enumerations)

---

## Title

CDC ECM USB Ethernet: AppleUserECM stops transmitting after exactly 161 packets per enumeration

---

## Description

When a USB CDC Ethernet (ECM) device is attached, macOS enumerates it correctly and the
resulting `enN` interface receives traffic indefinitely and without error. Transmission,
however, stops permanently after **exactly 161 packets**, counted from interface creation.

After that point:

- `netstat -I enN -b` shows `Opkts` frozen at 161 and never incrementing again
- `Oerrs` remains 0 and no error is logged anywhere in `log show` or the console
- the link continues to report `status: active`, `UP,RUNNING`, and a valid MTU
- inbound traffic continues normally and indefinitely
- the interface has valid addresses and correct on-link routes throughout
- `ping`, ARP resolution, and DHCP all fail silently, because nothing is transmitted
- packets submitted directly to `/dev/bpf` are also never transmitted

The only recovery is physically unplugging and reattaching the device, which creates a
new interface instance and buys exactly 161 more packets.

The count is 161 in every observed session, across ten independent enumerations, and is
insensitive to everything tried: interface bounce, `-tso` and other offload changes, MTU
changes, address reassignment, and re-adding routes. `Obytes` differs between sessions
while `Opkts` is identical, so the limit is on packet count and not on bytes.

### The packets are not merely lost — they are never transmitted

This was verified from the device side, using an instrument independent of both machines'
packet counters. The attached device is a Linux USB gadget whose USB controller interrupt
count is readable from `/proc/interrupts`. Sampling that count alongside the packet
counters every 10 seconds for 360 seconds, while this Mac transmitted continuously:

```
t(s)   device_rx_packets  device_tx_packets  device_usb_irq   note
10     1                  20                 128(+26)         rx +1
60     1                  58                 166(+8)          rx flat 50s
180    1                  149                257(+8)          rx flat 170s
360    1                  284                392(+7)          rx flat 350s
```

In all 36 intervals the controller's interrupt delta exactly equals its transmit
completion delta. Every interrupt the device's USB controller raised is accounted for by
an outbound completion; **not one is attributable to an inbound transfer.** The device's
controller was alive and interrupting normally for the entire run and never saw data
arrive from the Mac.

Device-side counters at the end of that run — nothing dropped, nothing errored:

```
rx_packets 1      rx_bytes 76       rx_errors 0       rx_dropped 0
rx_fifo_errors 0  rx_over_errors 0  rx_crc_errors 0   rx_missed_errors 0
```

Host-side at the same moment: `Ipkts=318  Opkts=161  Oerrs=0`.

macOS reported 161 packets transmitted. The receiving USB controller registered zero
inbound activity for any of them.

### Secondary symptom: the BSD interface intermittently carries a null MAC

In some enumerations the BSD interface is left with `02:00:00:00:00:00` while IOKit holds
the correct address parsed from the device's ECM descriptor. Observed live during a
wedged session:

```
BSD en7 MAC        : 02:00:00:00:00:00
IOKit IOMACAddress : <cada01211b05>
networksetup HW    : ca:da:01:21:1b:05
```

This is intermittent — other enumerations show the correct address on the BSD interface —
and it is **not** required for the transmit failure: sessions with the correct MAC applied
wedge at 161 identically. It is reported here because both symptoms are consistent with
the dext completing attach in a partially-initialised state, and the MAC discrepancy may
be the easier of the two to trace.

### Probable related symptom

Internet Sharing cannot bridge this interface, failing with a timeout on the same dext:

```
ioctl(..., SIOCSDRVSPEC) BRDGADD: failed Operation timed out
mis_bridge_add_int_if: add_bridge_member, err 60    # ETIMEDOUT
```

`tcpdump` likewise fails to enable promiscuous mode on the interface:

```
tcpdump: WARNING: enN: That device doesn't support promiscuous mode
(BIOCPROMISC: Operation timed out)
```

Both are control operations against the same driver returning `ETIMEDOUT`, which suggests
the failure is not confined to the data path.

### Speculation (offered only as a starting point)

The constancy of the number, the absence of any error, and recovery only on
re-enumeration are the shape of a fixed-size resource allocated at attach, consumed once
per transmit, and never returned. `AppleUserECM` is a DriverKit dext on
`IOSkywalkFamily`; a TX packet pool that is not recycled would produce exactly this
signature. This is inference from the failure's behaviour, not from any inspection of
Apple code.

---

## Steps to Reproduce

1. Configure any Linux device as a USB CDC ECM gadget. Reproduced with a Raspberry Pi
   Zero 2 W running Raspberry Pi OS (trixie), kernel `6.18.39+rpt-rpi-v8`, using the
   in-tree `g_ether` module (`dtoverlay=dwc2,dr_mode=peripheral`). Device presents as
   idVendor `0x2E8A`, idProduct `0x0013`, USB high-speed.
2. Attach it to the Mac by USB. It enumerates as
   `AppleUSBCDCCompositeDevice` → `AppleUserECM` → `IOSkywalkLegacyEthernet`, and a BSD
   interface appears (`en7` here).
3. Assign an address and confirm the on-link route exists:
   ```
   sudo ifconfig en7 inet 192.168.2.1 netmask 255.255.255.0 alias
   netstat -rn -f inet | grep en7        # expect: 192.168.2  link#N  UC  en7
   route -n get 192.168.2.2              # expect: interface: en7
   ```
4. Generate any sustained traffic — `ping`, ARP, DHCP, all behave the same.
5. Watch the transmit counter:
   ```
   while true; do netstat -I en7 -b | awk 'NR==2{print "Ipkts="$5" Opkts="$8" Oerrs="$9}'; sleep 5; done
   ```

**Expected:** `Opkts` increments for as long as traffic is offered.

**Actual:** `Opkts` climbs to exactly 161 and never increments again. `Ipkts` continues
climbing normally. `Oerrs` stays 0. Nothing is logged. Only a physical replug restores
transmission, for another exactly 161 packets.

---

## System

| | |
|---|---|
| Model | MacBook Air (Mac17,3), Apple M5, 24 GB |
| macOS | 27.0 beta, build 26A5421a |
| Kernel | Darwin 27.0.0, xnu-13432.1.9~3, RELEASE_ARM64_T8142 |
| Driver | `com.apple.DriverKit.AppleUserECM` (`IOUserClass=AppleUserECM`, `CFBundleIdentifierKernel=com.apple.iokit.IOSkywalkFamily`) |
| Device | USB CDC ECM gadget, VID `0x2E8A` PID `0x0013`, high-speed |

Note: two third-party network system extensions are active (Tailscale, Pangolin). The
failure was also observed with the interface fully addressed and routed independently of
both, and the device-side evidence above is unaffected by any host-side routing question.

---

## Attachments to include

- `diag4.txt` — device-side 360s capture with USB controller interrupt counts
- `hostside.txt` — host-side 400s counter log
- `txprobe.txt`, `bpf_en0.cap`, `bpf_en7.cap` — packet capture showing zero outbound on
  the gadget interface and 29/60 outbound on Wi-Fi as a control
- `opkts-161-session9.txt` — the counter freezing at 161 with routes verified present
- `wedged-snapshot.txt` — full interface, route, ARP and driver-stack state captured
  live while wedged, alongside the sysdiagnose
- Sysdiagnose captured while the interface is wedged

### Capturing the sysdiagnose

It must be taken while `Opkts` is frozen, not before or after. With the device attached
and the counter confirmed stuck at 161:

```sh
sudo sysdiagnose        # ~5 min; writes /var/tmp/sysdiagnose_*.tar.gz
```

The keyboard shortcut is Control-Option-Command-Shift-period, but the command is more
reliable and does not depend on focus. Confirm the wedge first:

```sh
netstat -I en7 -b | awk 'NR==2{print "Opkts="$8}'   # must read 161
```
