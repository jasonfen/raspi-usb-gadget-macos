Hit what looks like the same class of failure from a macOS host and posted the full data in #27 — short version: host→device delivery is essentially dead, device→host is fine.

Counters sampled simultaneously on both sides over one 280s session, Pi Zero 2 W / trixie / kernel 6.18.39, Apple Silicon host:

| direction | host | device |
|---|---|---|
| host → Pi | `netstat` Opkts = 161 (froze, Oerrs=0) | `usb0` `rx_packets` = **1** |
| Pi → host | Ipkts = 248 | `tx_packets` = 222 |

One packet arrived out of 161 the host's driver reported sending. Opkts froze at exactly 161 across five separate re-enumerations. I can't yet confirm the `ep_stop_xfr`/`txfifo_flush` signature your watchdog keys on — the Pi got unplugged before my sampling window closed — so I don't know whether this is your lockup or a different one. Rerunning with dmesg capture and will follow up either way.

Your commit 1 matches what I saw independently: six boots, six distinct gadget MACs, no `host_addr`/`dev_addr` in `g_ether.conf`.

**One thing worth checking in that commit though.** On this install `g_ether.conf` reads:

```
options g_ether idVendor=0x2E8A idProduct=0x0013 iManufacturer="Raspberry Pi Ltd." bcdDevice=0x0100 iProduct="Raspberry Pi USB Gadget" iSerialNumber=
```

`iSerialNumber` is empty — the existing `<serial>` substitution already produced an empty string here, so `SERIAL=$(awk '/^Serial/{print $3}' /proc/cpuinfo)` came back blank at install time. Most likely cause is the package being installed during image build in a chroot, where `/proc/cpuinfo` isn't the target board's. This image is a pwnagotchi build, so that path is plausible.

Since `mac_from_hash` in the new postinst hashes that same `$SERIAL`, an empty serial means every board derives its MACs from the same input and gets **identical** host/dev MACs — no longer per-board, and an outright collision if someone attaches two Pis to one host. Might be worth a fallback (`/sys/firmware/devicetree/base/serial-number`, machine-id, or a random-but-persisted value written on first boot) plus a guard that skips stamping if the serial is empty.

Happy to test a build of this branch on the setup above.
