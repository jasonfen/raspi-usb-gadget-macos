#!/bin/bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo root
# Capture what the Pi is actually putting on the wire.
# NOTE: macOS has no `timeout` command -- use background + kill instead.
INT=$(cat "$REPO/.gadget-if" 2>/dev/null)
[ -n "$INT" ] || INT=$(networksetup -listallhardwareports 2>/dev/null | awk '/Raspberry Pi USB Gadget/{getline; print $2}')
SECS="${1:-20}"
OUT="$REPO"/evidence/host/capture.txt

if [ "$(id -u)" -ne 0 ]; then
  echo "must run as root (tcpdump needs /dev/bpf)"; exit 1
fi

echo "capturing ${SECS}s on $INT ..."
: > "$OUT"
tcpdump -i "$INT" -n -e -l -v >> "$OUT" 2>&1 &
PID=$!
sleep "$SECS"
kill "$PID" 2>/dev/null
wait "$PID" 2>/dev/null

FRAMES=$(grep -cE "^[0-9]{2}:[0-9]{2}:[0-9]{2}" "$OUT" 2>/dev/null)
echo ""
echo "=================== SUMMARY ==================="
if grep -qiE "permission denied|no such device|syntax error" "$OUT" 2>/dev/null; then
  echo "!! tcpdump ERROR:"; grep -iE "permission|no such|error" "$OUT" | head -3 | sed 's/^/   /'
  exit 1
fi
echo "frames captured: $FRAMES"
if [ "${FRAMES:-0}" -eq 0 ]; then
  echo ""
  echo ">>> WIRE IS SILENT. The Pi is transmitting nothing at all."
  echo "    (Ipkts climbing earlier may have been counting our own multicast.)"
  exit 0
fi

echo ""
echo "--- source MACs ---"
grep -oE "^[0-9:.]+ [0-9a-f]{2}(:[0-9a-f]{2}){5}" "$OUT" | awk '{print $2}' | sort | uniq -c | sort -rn | head

echo ""
echo "--- protocols ---"
for p in "ARP" "who-has" "DHCP" "BOOTP" "ICMP6" "router solicitation" \
         "router advertisement" "mDNS" "5353" "UDP" "tcp"; do
  n=$(grep -ci "$p" "$OUT" 2>/dev/null)
  [ "${n:-0}" -gt 0 ] && printf "  %-24s %s\n" "$p" "$n"
done

echo ""
echo "--- addresses seen ---"
grep -oE "10\.12\.194\.[0-9]+|192\.168\.2\.[0-9]+|169\.254\.[0-9]+\.[0-9]+|fe80::[0-9a-f:]+" "$OUT" \
  | sort | uniq -c | sort -rn | head

echo ""
echo "--- ARP for 192.168.2.1? (= ICS watcher probing for us) ---"
if grep -i "who-has 192.168.2.1" "$OUT" | head -5; then
  echo "  ^^ watcher IS probing"
else
  echo "  NONE -- watcher is not probing for the macOS ICS gateway"
fi
echo "==============================================="
echo "full capture: $OUT"
