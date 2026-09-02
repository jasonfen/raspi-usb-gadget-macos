#!/bin/bash
# Snapshot gadget USB state. Run before sleep and after wake to compare.
TAG="${1:-snapshot}"
echo "=== $TAG  $(date +%H:%M:%S) ==="
ID=$(ioreg -p IOUSB -w0 2>/dev/null | grep -i "gadget" | grep -oE "id 0x[0-9a-f]+" | head -1)
echo "  registry id:  ${ID:-NOT ON BUS}   (a CHANGED id = it re-enumerated)"
NUBS=$(ioreg -p IOService -w0 -r -n "Raspberry Pi USB Gadget" 2>/dev/null | grep -c "IOUSBHostInterface")
echo "  iface nubs:   $NUBS   (need > 0)"
SESS=$(ioreg -p IOUSB -w0 -l -r -n "Raspberry Pi USB Gadget" 2>/dev/null | grep -oE '"sessionID" = [0-9]+' | head -1)
echo "  ${SESS:-sessionID: none}   (a CHANGED sessionID = it re-enumerated)"
IF=$(networksetup -listallhardwareports 2>/dev/null | awk '/Raspberry Pi USB Gadget/{getline; print $2}')
if [ -n "$IF" ] && ifconfig "$IF" >/dev/null 2>&1; then
  echo "  interface:    $IF LIVE"
  ifconfig "$IF" | grep -E "inet |status" | sed 's/^/    /'
else
  echo "  interface:    none live (profile says '${IF:-?}')"
fi
