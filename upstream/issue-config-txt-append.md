## `config.txt` overlay line can land inside a comment, and then can never be removed

`rpi-usb-gadget on` appends the overlay with a bare `>>`:

```sh
OVERLAY_LINE='dtoverlay=dwc2,dr_mode=peripheral'
...
sed -i "\|^$OVERLAY_LINE\$|d" "$CFG_FW" 2>/dev/null || true
printf '%s\n' "$OVERLAY_LINE" >> "$CFG_FW" 2>/dev/null || ...
```

### No trailing newline guard

If `config.txt` does not end in a newline, the append fuses onto the last line. On my card the last line was a comment:

```
#dtoverlay=disable-wifidtoverlay=dwc2,dr_mode=peripheral
```

Raw bytes, showing there was no newline before the append:

```
... e - w i f i d t o v e r l a y = d w c 2 , d r _ m o d e = p e r i p h e r a l \n
```

The whole line is a comment. The overlay never applies.

### Appending at EOF inherits the last conditional filter

With the newline fixed, the line still lands under whatever filter the file ends with. Mine ends:

```
[pi5]
dtoverlay=spi0-2cs
#dtoverlay=disable-wifi     <- append landed here
```

A Zero 2 W reads `[pi02]`, not `[pi5]`. Stock Raspberry Pi OS `config.txt` also ends in a `[pi5]` section.

### The anchored sed cannot match a fused line

Dedupe and removal share one pattern:

```sh
sed -i "\|^$OVERLAY_LINE\$|d" "$CFG_FW"
```

It matches `^dtoverlay=dwc2,dr_mode=peripheral$`, which `#dtoverlay=disable-wifidtoverlay=dwc2,dr_mode=peripheral` is not. Consequences:

- the "ensure overlay present once" dedupe never fires, so every `rpi-usb-gadget on` appends another copy
- `rpi-usb-gadget off` cannot remove it
- postrm cannot clean it on uninstall

The file accumulates inert fragments the tool can no longer see.

### Symptoms

The gadget still enumerates. Anything else in `config.txt` that loads the dwc2 overlay, such as the bare `dtoverlay=dwc2` under `[all]` that pwnagotchi images ship, brings the driver up with `dr_mode` at its `otg` default. On a normal micro-USB cable the ID pin floats and the controller settles into device mode regardless, so the gadget looks healthy. Nothing is logged.

The observable difference is in dmesg. In `otg` mode dwc2 also registers a host controller:

```
dwc2 3f980000.usb: DWC OTG Controller
dwc2 3f980000.usb: new USB bus registered, assigned bus number 1
dwc2 3f980000.usb: irq 51, io mem 0x3f980000
usb usb1: Manufacturer: Linux 6.18.39+rpt-rpi-v8 dwc2_hsotg
```

Those four lines are absent in `peripheral` mode. `/proc/device-tree/soc/usb@7e980000/dr_mode` reads `peripheral` once the line is placed under `[all]`.

### Suggested fix

```sh
# guarantee a newline before appending
[ -n "$(tail -c1 "$CFG_FW")" ] && printf '\n' >> "$CFG_FW"
# emit an explicit filter rather than inheriting one
printf '[all]\n%s\n' "$OVERLAY_LINE" >> "$CFG_FW"
```

Matching the fragment anywhere on a line, rather than anchoring to the whole line, would let `off` and postrm clean up files already in this state.

### Environment

Pi Zero 2 W, Raspberry Pi OS trixie, kernel 6.18.39+rpt-rpi-v8, pwnagotchi based image. Found while chasing an unrelated host side problem that turned out to be a macOS bug (FB24614121), written up in my withdrawal on #27.
