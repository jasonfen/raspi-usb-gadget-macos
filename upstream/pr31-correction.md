Correcting my earlier comment on the serial, and reporting back on the dmesg capture.

**Serial:** I said the awk in postinst comes back blank and guessed chroot. On the running board it isn't blank:

```
$ grep -i '^Serial' /proc/cpuinfo
Serial          : 000000001bda2cd5
$ cat /sys/firmware/devicetree/base/serial-number
000000001bda2cd5
```

So the serial is available at runtime, yet `g_ether.conf` still has `iSerialNumber=` empty. That points at the file being stamped at image build time, when `/proc/cpuinfo` wasn't the target board's, rather than the awk failing on a running system.

That changes what a fix needs to do. A guard that skips stamping on an empty serial protects fresh installs but does nothing for images that already shipped with a blank value, and those are the ones that will collide once `mac_from_hash` starts deriving from the same field. Re-stamping on first boot when the value is empty would cover both. `/sys/firmware/devicetree/base/serial-number` looks like a reasonable source if `/proc/cpuinfo` is unavailable.

**dmesg:** ran a full 6 minute capture with snapshots every 60s. No `ep_stop_xfr`, no `txfifo_flush`, no timeouts, no resets. dmesg is byte identical at every snapshot, nothing logged after `bound driver g_ether`. So whatever I'm hitting doesn't produce the messages your watcher keys on. If it is the same underlying lockup then only your rx_packets fallback would catch it.

For what it's worth the shape is: host queues 161 packets with no errors, device receives 1 with no drops and no errors, carrier stays up the whole time, `usb0` is `UP,LOWER_UP` with `10.12.194.1/28`. Full numbers in raspberrypi/rpi-usb-gadget#27.

Still happy to test a build of this branch.
