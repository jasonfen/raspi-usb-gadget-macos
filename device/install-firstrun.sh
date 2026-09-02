#!/bin/bash
# Install the one-shot diagnostic onto the SD card's boot partition.
# Run with the card mounted on the Mac.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo root
# Pi boot partition: override with BOOTFS=..., else find the mounted FAT volume
# that carries both config.txt and cmdline.txt.
B="${BOOTFS:-}"
if [ -z "$B" ]; then
  for c in /Volumes/*; do
    [ -f "$c/config.txt" ] && [ -f "$c/cmdline.txt" ] && { B="$c"; break; }
  done
fi

[ -d "$B" ] || { echo "bootfs not mounted -- insert the SD card"; exit 1; }

echo "=== current cmdline.txt ==="
cat "$B/cmdline.txt"

# always restore from the pristine backup, so repeated runs don't stack params
if [ -f "$REPO/backup/device/cmdline.txt.orig" ]; then
  ORIG=$(tr -d '\n' < "$REPO/backup/device/cmdline.txt.orig")
else
  ORIG=$(tr -d '\n' < "$B/cmdline.txt")
fi

echo ""
echo "=== installing firstrun.sh ==="
cp "$REPO/device/firstrun.sh" "$B/firstrun.sh" || exit 1
chmod 755 "$B/firstrun.sh" 2>/dev/null
ls -l "$B/firstrun.sh"

echo ""
echo "=== saving pristine cmdline for the Pi to restore ==="
printf '%s\n' "$ORIG" > "$B/cmdline.txt.preflight"
cat "$B/cmdline.txt.preflight"

echo ""
echo "=== new cmdline.txt (one line) ==="
printf '%s systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target\n' "$ORIG" > "$B/cmdline.txt"
cat "$B/cmdline.txt"
echo "lines: $(wc -l < "$B/cmdline.txt")  (must be 1)"

echo ""
echo "Now: eject, boot the Pi, wait ~2.5 min (it sleeps 60s, dumps, reboots),"
echo "then put the card back here and run:  ./read-diag.sh"
