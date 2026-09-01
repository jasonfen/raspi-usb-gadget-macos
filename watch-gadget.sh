#!/bin/bash
# Poll for the gadget to appear and compose interfaces. Run right after a replug.
# Usage: ./watch-gadget.sh [seconds]   (default 180)
MAX="${1:-180}"
echo "watching for up to ${MAX}s ..."
SEEN_BUS=""
for t in $(seq 0 3 "$MAX"); do
  ID=$(ioreg -p IOUSB -w0 2>/dev/null | grep -i "gadget" | grep -oE "id 0x[0-9a-f]+" | head -1)
  if [ -n "$ID" ]; then
    NUBS=$(ioreg -p IOService -w0 -r -n "Raspberry Pi USB Gadget" 2>/dev/null | grep -c "IOUSBHostInterface")
    if [ -z "$SEEN_BUS" ]; then
      echo ""
      echo "[t+${t}s] ON BUS: $ID"
      SEEN_BUS=1
    fi
    if [ "$NUBS" -gt 0 ]; then
      echo "[t+${t}s] *** INTERFACES COMPOSED: $NUBS nubs ***"
      IF=$(networksetup -listallhardwareports 2>/dev/null | awk '/Raspberry Pi USB Gadget/{getline; print $2}')
      echo "    interface: ${IF:-still resolving}"
      [ -n "$IF" ] && ifconfig "$IF" 2>/dev/null | grep -E "inet |status" | sed 's/^/    /'
      echo ""
      echo ">>> READY -- run: sudo ./ics-emulate.sh"
      exit 0
    fi
    printf "n"
  else
    printf "."
  fi
  sleep 3
done
echo ""
echo ">>> TIMED OUT after ${MAX}s"
echo "    '.' = not on bus at all   'n' = on bus but 0 interface nubs"
[ -z "$SEEN_BUS" ] && echo "    Never appeared: Pi not booting, or cable is power-only/damaged." \
                   || echo "    Appeared but never composed: gadget service failing on the Pi."
