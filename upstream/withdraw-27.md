Withdrawing this. The fault is on the macOS side, not in rpi-usb-gadget.

I re-tested with the dwc2 interrupt count sampled next to the packet counters, which is independent of either machine's packet accounting. Over 360s, every 10s interval showed the device's dwc2 IRQ delta exactly equal to its tx_packets delta, all 36 intervals, no exceptions. Every interrupt the gadget's USB controller raised was an outbound completion. None were attributable to an inbound transfer. Device side finished with rx_packets 1 and zero on every error and drop counter, while the host reported Opkts 161.

The host's packets never reach the wire. macOS AppleUserECM halts transmit after exactly 161 packets per enumeration, ten enumerations for ten, Oerrs 0, nothing logged, cleared only by replug. Filed with Apple as FB24614121.

My earlier numbers here were real but I read them wrong. I treated a frozen host counter as evidence of a delivery problem between the two machines, when it was the host declining to transmit at all. Sorry for the noise.

Two things from this thread still stand on their own and are not caused by the above:

- `g_ether.conf` ships `iSerialNumber=` empty, covered in my PR #31 comments.
- The installer appends `dtoverlay=dwc2,dr_mode=peripheral` to the end of config.txt without a trailing newline guard and without forcing an `[all]` filter. On my card it concatenated onto a preceding `#dtoverlay=disable-wifi` comment and landed under `[pi5]`, so it was inert twice over and the board ran in otg mode. Worth a separate issue if useful.
