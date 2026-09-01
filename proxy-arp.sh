#!/bin/bash
# The Pi probes: "who-has 192.168.2.1 tell 10.12.194.1".
# macOS won't answer -- sender is on a different subnet than the target.
# Publish an ARP entry so we reply anyway, which is all the ICS watcher needs.
[ "$(id -u)" -ne 0 ] && { echo "run as root"; exit 1; }
INT=$(cat /Users/jason/Documents/projects/raspi/.gadget-if 2>/dev/null || echo en7)
OUT=/Users/jason/Documents/projects/raspi/proxy-capture.txt

MAC=$(ifconfig "$INT" | awk '/ether/{print $2}')
echo "=== $INT mac: $MAC ==="
[ -z "$MAC" ] && { echo "no MAC found"; exit 1; }

echo ""
echo "=== before: does anything answer? (12s capture) ==="
: > "$OUT"
tcpdump -i "$INT" -n -e -l arp >> "$OUT" 2>&1 &
P=$!; sleep 12; kill $P 2>/dev/null; wait $P 2>/dev/null
echo "  frames: $(grep -cE '^[0-9]{2}:' "$OUT")"
echo "  replies from us: $(grep -ci "Reply 192.168.2.1" "$OUT")"

echo ""
echo "=== installing published ARP entry for 192.168.2.1 ==="
arp -d 192.168.2.1 2>/dev/null
arp -s 192.168.2.1 "$MAC" pub 2>&1 && echo "  installed" || echo "  REJECTED"
arp -an | grep 192.168.2.1 | sed 's/^/  /'

echo ""
echo "=== after: are we replying now? (20s capture) ==="
: > "$OUT"
tcpdump -i "$INT" -n -e -l arp >> "$OUT" 2>&1 &
P=$!; sleep 20; kill $P 2>/dev/null; wait $P 2>/dev/null
echo "  total arp frames: $(grep -cE '^[0-9]{2}:' "$OUT")"
echo "  probes from Pi:   $(grep -ci 'who-has 192.168.2.1' "$OUT")"
echo "  OUR REPLIES:      $(grep -ci 'Reply 192.168.2.1' "$OUT")"
echo ""
grep -iE "who-has 192.168.2.1|Reply 192.168.2.1" "$OUT" | tail -6 | sed 's/^/  /'

echo ""
echo "=== did the Pi flip? (waiting 45s for DHCP) ==="
for t in 0 15 30 45; do
  L=$(grep -c "192.168.2" /var/db/dhcpd_leases 2>/dev/null)
  A=$(arp -an | grep -c "192.168.2\.[2-9]")
  printf "  t+%-3ss  leases=%s  arp=%s\n" "$t" "${L:-0}" "${A:-0}"
  [ "${L:-0}" -gt 0 ] && { echo "  *** PI GOT A LEASE ***"; break; }
  sleep 15
done

echo ""
grep -A4 "192.168.2" /var/db/dhcpd_leases 2>/dev/null | sed 's/^/  /' || echo "  no lease yet"
echo ""
echo "Remove the published entry with:  sudo arp -d 192.168.2.1"
