#!/bin/bash
# Poll for the SD card to appear. Run, then reseat the card.
echo "watching for the card (60s) ... reseat it now"
for t in $(seq 0 2 60); do
  # any external/removable whole disk that is not the internal one
  D=$(diskutil list 2>/dev/null | grep -E "^/dev/disk[0-9]+ \(external, physical\)" | head -1 | awk '{print $1}')
  if [ -n "$D" ]; then
    echo ""
    echo "[t+${t}s] CARD DETECTED: $D"
    diskutil list "$D" 2>/dev/null | sed 's/^/  /'
    echo ""
    echo "  mounted volumes:"
    ls -1 /Volumes 2>/dev/null | grep -viE "^Macintosh HD$|^Recovery$" | sed 's/^/    /' || echo "    (none yet)"
    exit 0
  fi
  printf "."
  sleep 2
done
echo ""
echo "no card after 60s."
echo "  reader on bus: $(ioreg -p IOUSB -w0 2>/dev/null | grep -c 'USB Storage') device(s)"
echo "  Try: different slot, different reader, or another USB port (not the hub)."
