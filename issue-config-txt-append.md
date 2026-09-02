## `config.txt` overlay line can land inside a comment, and then can never be removed

`rpi-usb-gadget on` appends the overlay with a bare `>>`:

```sh
OVERLAY_LINE='dtoverlay=dwc2,dr_mode=peripheral'
...
sed -i "\|^$OVERLAY_LINE\$|d" "$CFG_FW" 2>/dev/null || true
printf '%s\n' "$OVERLAY_LINE" >> "$CFG_FW" 2>/dev/null || ...
```

Two problems with that, and a third that follows from them.

### 1. No trailing newline guard

If `config.txt` does not end in a newline, the append fuses onto the last line. On my card the last line was a comment, so I got:

```
#dtoverlay=disable-wifidtoverlay=dwc2,dr_mode=peripheral
```

Raw bytes, confirming there was no newline before the append:

```
... e - w i f i d t o v e r l a y = d w c 2 , d r _ m o d e = p e r i p h e r a l \n
```

The whole line is a comment. The overlay never applies.

### 2. Appending at EOF inherits whatever conditional filter came last

Even with the newline fixed, the line lands under whatever filter the file happens to end with. Mine ends:

```
[pi5]
dtoverlay=spi0-2cs
#dtoverlay=disable-wifi     <- append landed here
```

That is a `[pi5]` block on a Zero 2 W, which reads `[pi02]`. Stock Raspberry Pi OS `config.txt` also ends in a `[pi5]` section, so this is not an exotic starting state.

### 3. Once fused, the line is unremovable and duplicates on every run

The dedupe and the removal both use the same anchored pattern:

```sh
sed -i "\|^$OVERLAY_LINE\$|d" "$CFG_FW"
```

which matches `^dtoverlay=dwc2,dr_mode=peripheral$`. Against `#dtoverlay=disable-wifidtoverlay=dwc2,dr_mode=peripheral` it matches nothing. So:

- the "ensure overlay present once" dedupe never fires, and every `rpi-usb-gadget on` appends another copy
- `rpi-usb-gadget off` cannot remove it
- postrm cannot clean it on uninstall

The file accumulates inert fragments that the tool that wrote them can no longer see.

### Why this is easy to miss

The gadget still enumerates. If anything else in `config.txt` loads the dwc2 overlay, and pwnagotchi images do exactly that with a bare `dtoverlay=dwc2` under `[all]`, the driver loads with `dr_mode` at its `otg` default. With a normal micro-USB cable the ID pin floats, the controller settles into device mode anyway, and you get a working looking gadget. Nothing warns.

The only visible difference is in dmesg. In `otg` mode dwc2 also registers a host controller:

```
dwc2 3f980000.usb: DWC OTG Controller
dwc2 3f980000.usb: new USB bus registered, assigned bus number 1
dwc2 3f980000.usb: irq 51, io mem 0x3f980000
usb usb1: Manufacturer: Linux 6.18.39+rpt-rpi-v8 dwc2_hsotg
```

In `peripheral` mode those four lines are absent. That diff is the only way I found it, after the device tree confirmed `dr_mode` was never set.

### Suggested fix

```sh
# guarantee a newline before appending
[ -n "$(tail -c1 "$CFG_FW")" ] && printf '\n' >> "$CFG_FW"
# always emit an explicit filter rather than inheriting one
printf '[all]\n%s\n' "$OVERLAY_LINE" >> "$CFG_FW"
```

For removal, matching the fragment anywhere on a line rather than anchoring to the whole line would also let `off` and postrm clean up files already in this state.

### Environment

Pi Zero 2 W, Raspberry Pi OS trixie, kernel 6.18.39+rpt-rpi-v8, pwnagotchi based image. Found while chasing an unrelated host side problem, which turned out to be a macOS bug (FB24614121) and is written up in my withdrawal on #27.
