Following up on my two comments above. The host to device failure I reported is a macOS bug, not the lockup this PR handles, so please disregard that part.

I re-tested with the dwc2 interrupt count sampled alongside the packet counters. Across all 36 ten second intervals of a 360s run, the device's dwc2 IRQ delta exactly matched its tx_packets delta, so every interrupt was an outbound completion and none came from an inbound transfer. The gadget's controller never saw the host's packets. macOS AppleUserECM stops transmitting after exactly 161 packets per enumeration with Oerrs 0 and nothing logged. Filed as FB24614121.

That also explains why I could not find your `ep_stop_xfr` or `txfifo_flush` signature. There was nothing wrong on the device side to log.

The MAC part of my comments is unaffected and still stands. No `host_addr`/`dev_addr` in `g_ether.conf` gives a fresh random MAC every boot, ten distinct ones across ten boots here, and `iSerialNumber=` is empty on this image, so `mac_from_hash` would derive from a blank input. The re-stamping point in my correction above still applies.

Happy to test a build of this branch, though I can no longer offer a working macOS host as a test bed until Apple fixes theirs.
