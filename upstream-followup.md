Ran the full 6 minute capture I promised, with dmesg snapshots every 60s. Results below, and they rule out two things I'd flagged as possible.

Same setup as before: Pi Zero 2 W, trixie, kernel 6.18.39+rpt-rpi-v8, Apple Silicon host on macOS 27.0 beta.

### Counters

| | host (macOS) | device (usb0) |
|---|---|---|
| host to Pi | Opkts 161, Obytes 44858, Oerrs 0 | rx_packets **1**, rx_bytes 76 |
| Pi to host | Ipkts 346 | tx_packets 291 |

Device side reports `errors 0, dropped 0, missed 0` on RX. The single packet arrived within the first 10 seconds. Nothing for the remaining 350.

```
t(s)    rx_packets   tx_packets   carrier
0       0            0            ?
10      1            20           1
20      1            27           1
...
350     1            276          1
360     1            284          1
```

Host Opkts sat at exactly 161 again, sixth session running.

### This is not the NO-CARRIER failure in #29

`carrier=1` on every sample. Final state:

```
2: usb0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UP
   inet 10.12.194.1/28
```

The link is up, SHARED mode is applied, the gadget transmits fine. I said otherwise in my last comment based on a reading taken before the interface finished coming up. That was wrong.

### No dwc2 errors, at all

dmesg is byte identical at t=60, 120, 180, 240, 300 and 360. Nothing logged after bind:

```
g_ether gadget.0: g_ether ready
dwc2 3f980000.usb: bound driver g_ether
dwc2 3f980000.usb: new device is high-speed
dwc2 3f980000.usb: new address 4
```

No `ep_stop_xfr`, no `txfifo_flush`, no timeouts, no resets. So this is not the logged signature PR #31 keys on. Could be the silent variant its rx_packets fallback watchdog covers, or something else entirely.

### Where I think this sits

Both sides report success. The host's driver counts 161 packets sent with no errors. The device counts 1 received, with no drops and no errors. Neither kernel logs anything. The OUT path is silently discarding data somewhere between the two.

Given #19's reporter had the same Pi work correctly against a NixOS host, my guess is the macOS side never actually submits or completes those transfers, and Opkts is counting them as done regardless. I can't prove that from counters on either end, so treating it as a guess rather than a finding.

Relevant to this issue specifically: the 169.254 fallback isn't a DHCP timing problem. DHCP can't complete when the host's packets don't reach the device at all. Widening the client probe window won't help this case.

Happy to attach the full dumps or the collection scripts if useful.
