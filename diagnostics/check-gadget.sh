#!/bin/bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo root
# Run AFTER replugging. Did the gadget enumerate with real interfaces this time?
echo "=== USB device present? ==="
ioreg -p IOUSB -w0 2>/dev/null | grep -i "gadget" || echo "  NOT ON THE BUS -- cable/port problem"

echo ""
echo "=== configuration + interface nubs (want nubs > 0) ==="
ioreg -p IOUSB -w0 -l -r -n "Raspberry Pi USB Gadget" 2>/dev/null \
  | grep -E "kUSBCurrentConfiguration|bNumConfigurations" | sort -u
NUBS=$(ioreg -p IOService -w0 -r -n "Raspberry Pi USB Gadget" 2>/dev/null | grep -c "IOUSBHostInterface")
echo "  IOUSBHostInterface nubs: $NUBS"
[ "$NUBS" -gt 0 ] && echo "  >>> GOOD: interfaces composed" || echo "  >>> STILL EMPTY: reboot the Pi next"

echo ""
echo "=== gadget network interface (BSD name) ==="
GADGET=$(networksetup -listallhardwareports 2>/dev/null \
  | awk '/Raspberry Pi USB Gadget/{getline; print $2}')
if [ -n "$GADGET" ] && ifconfig "$GADGET" >/dev/null 2>&1; then
  echo "  FOUND: $GADGET"
  ifconfig "$GADGET" | grep -E "inet |status|media"
  echo "$GADGET" > $REPO/.gadget-if
else
  echo "  no live interface yet (service profile may exist without hardware)"
  echo "  --- all en* interfaces present ---"
  ifconfig -a 2>/dev/null | grep -E "^en[0-9]+:" | cut -d: -f1 | tr '\n' ' '; echo
fi

echo ""
echo "=== ethernet interfaces in ioreg ==="
ioreg -c IOEthernetInterface -r -d1 2>/dev/null | grep '"BSD Name"' | tr -d ' "' | sed 's/^/  /'
