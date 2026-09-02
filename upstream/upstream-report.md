Spent some time instrumenting this on my own setup and I don't think the root cause is a DHCP timing race. In my captures, host→device packets essentially never arrive at the gadget at all — DHCP (or anything else) couldn't complete regardless of how long the watcher waits. Posting the data in case it's useful, and flagging the overlap with #29/#16 and PR #31 since I can't tell from this alone whether it's the same underlying issue.

### Environment

- Host: Apple Silicon MacBook, macOS 27.0 beta (26A5421a)
- Device: Pi Zero 2 W, Raspberry Pi OS trixie (Debian 13), kernel 6.18.39+rpt-rpi-v8
- rpi-usb-gadget installed, legacy `g_ether` composition (configfs gadget dir is empty)
- Pi running pwnagotchi, `wlan0` in use, so USB is the only link to the device
- micro-USB OTG cable through a Genesys Logic USB2.1 hub

### Key finding: simultaneous counters, both sides, one 280s session

| direction | host counter | device counter |
|---|---|---|
| Mac → Pi | `netstat` Opkts = 161 (froze there, Oerrs=0) | `/sys/class/net/usb0/statistics/rx_packets` = 1 |
| Pi → Mac | `netstat` Ipkts = 248 | `tx_packets` = 222 |

Device→host works fine. Host→device delivered exactly one packet out of 161 the host's driver believed it sent — Opkts counts queued/completed-by-driver, not delivered. Opkts stopped at exactly 161 across five separate physical re-enumerations, same number every time, Oerrs always 0, link reported UP/RUNNING/active on the host the whole time.

Other things measured, not embellished:

- Pi side during sampling: `usb0` operstate=down, carrier file empty, UDC `3f980000.usb` state=configured, soft_connect empty — yet it transmitted 222 packets successfully in that state.
- macOS enumerates correctly: CDC-ECM, binds AppleUserECM → IOSkywalkLegacyEthernet → en7, 2 IOUSBHostInterface nubs, kUSBCurrentConfiguration=1.
- tcpdump on the host shows the Pi's ICS probes arriving normally, ~every 4s, cycling all three gateways (`who-has 10.42.0.1 / 192.168.137.1 / 192.168.2.1 tell 10.12.194.1`).
- Hand-emulated macOS ICS (192.168.2.1/24 on the gadget interface, bootpd scoped to it, pf NAT, `net.inet.ip.forwarding=1`) so a userspace ARP responder could answer the Pi's probes — it answered ~47 of them. The Pi never switched to CLIENT mode, consistent with those replies never arriving.
- Raw frame injection from the host (BPF write, AF_NDRV connect+write, AF_NDRV sendto) all returned success and incremented Opkts, but nothing reached the Pi.
- Internet Sharing itself fails on this interface: `ioctl SIOCSDRVSPEC BRDGADD` on bridge100 returns "Operation timed out" (60), so Sharing never assigns an address. Consistent with the same transport failure, not a config issue.
- Host DHCP client falls back to 169.254.x, matching the symptom reported in #27.

Two unrelated packaging observations while I was in there: `/usr/lib/modprobe.d/g_ether.conf` has `iSerialNumber=` empty — the `<serial>` placeholder isn't getting substituted by postinst. And with no `host_addr`/`dev_addr` set, u_ether randomizes the MAC pair every module load — six boots, six distinct gadget MACs. PR #31's first commit addresses the MAC part; the empty iSerialNumber looks like a separate bug.

### What I didn't capture

Post-session dmesg — the Pi got unplugged before the sampling window closed, so I can't confirm or rule out the `ep_stop_xfr`/`txfifo_flush` signature that PR #31 keys on. Also can't tell from counters alone which side is dropping the packets: #19's reporter had the same Pi work against a NixOS host (points at the macOS driver), while #16/#29 point at dwc2 on Zero 2 W + Trixie. My data is consistent with either.

### Methodology note

No shell/serial access to the Pi — USB was the only path. Device-side stats were collected by dropping a one-shot systemd service onto the FAT boot partition from the Mac, launched via `systemd.run=/boot/firmware/firstrun.sh` with `systemd.unit=kernel-command-line.target` in cmdline.txt. It sampled `/sys/class/net/usb0/statistics` every 10s, wrote results back to the boot partition for macOS to read, then removed itself.

Happy to rerun with dmesg capture across the drop, or test a patched build if one's available.
