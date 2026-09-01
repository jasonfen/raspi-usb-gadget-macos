#!/bin/bash
# Read diagnostics the Pi wrote to the boot partition.
B=/Volumes/bootfs
DEST=/Users/jason/Documents/projects/raspi
[ -d "$B" ] || { echo "bootfs not mounted -- insert the SD card"; exit 1; }

[ -f "$B/stage1.log" ] && echo "stage1: $(cat "$B/stage1.log")" || echo "stage1: DID NOT RUN"

if [ -f "$B/diag2.txt" ]; then
  cp "$B/diag2.txt" "$DEST/diag2.txt"
  echo "copied to $DEST/diag2.txt"
  echo "=================================================="
  cat "$B/diag2.txt"
elif [ -f "$B/diag.txt" ]; then
  cp "$B/diag.txt" "$DEST/diag.txt"; echo "(only stage-0 diag.txt present)"; cat "$B/diag.txt"
else
  echo "no diag2.txt -- the sampling service has not run yet"
  echo "cmdline.txt: $(cat "$B/cmdline.txt")"
  [ -f "$B/cmdline.txt.preflight" ] && echo "(preflight still present = stage 1 never completed)"
fi
