#!/bin/bash
# Start the ARP responder and watch for the Pi to flip to client mode.
[ "$(id -u)" -ne 0 ] && { echo "run as root"; exit 1; }
BASE=/Users/jason/Documents/projects/raspi
INT=$(cat "$BASE/.gadget-if" 2>/dev/null || echo en7)
LOG="$BASE/responder.log"

pkill -f arp-responder.py 2>/dev/null
sleep 1

echo "=== preconditions ==="
ifconfig "$INT" | grep -E "inet |status" | sed 's/^/  /'
echo "  forwarding: $(sysctl -n net.inet.ip.forwarding)"
echo "  bootpd:     $(pgrep -x bootpd >/dev/null && echo running || echo NOT RUNNING)"
pfctl -a pi-nat -s nat 2>/dev/null | grep -v ALTQ | sed 's/^/  /'

echo ""
echo "=== starting responder on $INT ==="
python3 "$BASE/arp-responder.py" "$INT" 192.168.2.1 > "$LOG" 2>&1 &
RPID=$!
sleep 3
if ! kill -0 "$RPID" 2>/dev/null; then
  echo "  FAILED to start:"; cat "$LOG" | sed 's/^/    /'; exit 1
fi
head -2 "$LOG" | sed 's/^/  /'

echo ""
echo "=== waiting for the Pi to notice us (probes every ~4s) ==="
for t in $(seq 0 10 120); do
  R=$(grep -c "replied to" "$LOG" 2>/dev/null)
  L=$(grep -c "192.168.2" /var/db/dhcpd_leases 2>/dev/null)
  A=$(arp -an | grep -cE "192\.168\.2\.[2-9]" )
  printf "  t+%-4ss  arp_replies=%-4s leases=%-3s pi_arp=%s\n" "$t" "${R:-0}" "${L:-0}" "${A:-0}"
  if [ "${L:-0}" -gt 0 ]; then echo ""; echo "  *** PI GOT A LEASE ***"; break; fi
  sleep 10
done

echo ""
echo "=== leases ==="
grep -A4 "192.168.2" /var/db/dhcpd_leases 2>/dev/null | sed 's/^/  /' || echo "  none"
echo "=== arp ==="
arp -an | grep "$INT" | grep -v incomplete | sed 's/^/  /'
echo "=== responder log (tail) ==="
tail -6 "$LOG" | sed 's/^/  /'

echo ""
PI=$(grep -A4 "192.168.2" /var/db/dhcpd_leases 2>/dev/null | grep ip_address | head -1 | cut -d= -f2)
if [ -n "$PI" ]; then
  echo "Pi is at $PI -- test it:"
  echo "  ping -c3 $PI"
  echo "  ssh pi@$PI"
else
  echo "No lease yet. Responder still running (pid $RPID), log: $LOG"
  echo "Stop it with: sudo pkill -f arp-responder.py"
fi
