#!/bin/bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo root
B=/Volumes/bootfs
[ -f "$B/diag4.txt" ] || { echo "diag4.txt ABSENT"; ls -la $B/ | grep -iE "diag|stage1|pcap|cmdline"; exit 1; }
cp "$B/diag4.txt" "$REPO/evidence/device/diag4.txt"
[ -f "$B/usb0.pcap" ] && cp "$B/usb0.pcap" "$REPO/evidence/device/usb0.pcap"

echo "############ STAGE1 / FRESHNESS ############"
cat "$B/stage1.log" 2>/dev/null; echo "cmdline: $(cat $B/cmdline.txt)"
echo
echo "############ DR_MODE ############"
sed -n '/dr_mode (find -L/,/dwc2 module params/p' "$REPO/evidence/device/diag4.txt" | head -12
echo
echo "############ DEBUGFS AVAILABLE? ############"
sed -n '/debugfs mounted?/,/irq line/p' "$REPO/evidence/device/diag4.txt" | head -12
echo
echo "############ THE DISCRIMINATOR: irq vs rx ############"
sed -n '/^t(s)/,/^$/p' "$REPO/evidence/device/diag4.txt" | head -42
echo
echo "############ WEDGED SNAPSHOT ############"
sed -n '/WEDGED/,/^$/p' "$REPO/evidence/device/diag4.txt" | head -60
echo
echo "############ FINAL STATS ############"
sed -n '/usb0 full statistics/,/dmesg AFTER/p' "$REPO/evidence/device/diag4.txt"
echo
echo "############ ERRORS LOGGED ############"
sed -n '/anything logged at all/,/pcap/p' "$REPO/evidence/device/diag4.txt" | head -25
