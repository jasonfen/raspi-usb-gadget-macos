#!/bin/bash
# Are our ARP replies actually reaching the wire?
# The responder logging a write only proves os.write() returned.
[ "$(id -u)" -ne 0 ] && { echo "run as root"; exit 1; }
BASE=/Users/jason/Documents/projects/raspi
INT=$(cat "$BASE/.gadget-if" 2>/dev/null || echo en7)
OUT=/tmp/_verify_arp.txt

pgrep -f arp-responder.py >/dev/null || { echo "responder NOT running -- start full-setup.sh first"; exit 1; }
echo "responder pid: $(pgrep -f arp-responder.py)"

A=$(netstat -I "$INT" -b 2>/dev/null | awk 'NR==2{print $8}')
LOGA=$(grep -c "replied to" "$BASE/responder.log" 2>/dev/null)

echo "capturing 20s of ARP on $INT ..."
: > "$OUT"
tcpdump -i "$INT" -n -e -l arp >> "$OUT" 2>&1 &
P=$!; sleep 20; kill $P 2>/dev/null; wait $P 2>/dev/null

B=$(netstat -I "$INT" -b 2>/dev/null | awk 'NR==2{print $8}')
LOGB=$(grep -c "replied to" "$BASE/responder.log" 2>/dev/null)

echo ""
echo "=== over those 20s ==="
echo "  responder logged writes: $((LOGB-LOGA))"
echo "  Opkts delta:             $((B-A))"
echo "  probes seen from Pi:     $(grep -ci 'who-has 192.168.2.1' "$OUT")"
echo "  REPLIES SEEN ON WIRE:    $(grep -ci 'Reply 192.168.2.1' "$OUT")"
echo ""
grep -iE "who-has 192.168.2.1|Reply 192.168.2.1" "$OUT" | tail -8 | sed 's/^/  /'
echo ""
R=$(grep -ci 'Reply 192.168.2.1' "$OUT")
if [ "${R:-0}" -gt 0 ]; then
  echo ">>> replies ARE on the wire. The Pi is receiving them and choosing"
  echo "    not to switch. That is a Pi-side watcher decision -- needs its logs."
else
  echo ">>> replies are NOT on the wire despite successful writes."
  echo "    BPF writes are being swallowed; the Pi never sees an answer."
fi
rm -f "$OUT"
