#!/bin/bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo root
TMPF=$(mktemp -t pidiag); trap 'rm -f "$TMPF"' EXIT
# Did the Pi flip to client mode and pick up a lease?
INT=$(cat "$REPO/.gadget-if" 2>/dev/null)
[ -n "$INT" ] || INT=$(networksetup -listallhardwareports 2>/dev/null | awk '/Raspberry Pi USB Gadget/{getline; print $2}')
echo "(gadget interface: $INT)"

echo ""
echo "=== DHCP leases handed out ==="
grep -A4 "192.168.2" /var/db/dhcpd_leases 2>/dev/null || echo "  no 192.168.2.x lease yet"

echo ""
echo "=== ARP on $INT (resolved entry = Pi talking IPv4 to us) ==="
arp -an | grep "$INT" || echo "  (none)"

echo ""
echo "=== counters ==="
netstat -I "$INT" -b 2>/dev/null | awk 'NR==2 {print "  Ipkts=" $5 "   Opkts=" $8 "   (Opkts climbing = we are transmitting)"}'

echo ""
echo "=== scan 192.168.2.2-20 ==="
for i in $(seq 2 20); do
  ( ping -c1 -W300 -q 192.168.2.$i >/dev/null 2>&1 && echo "  192.168.2.$i REPLIES" ) &
done
wait

echo ""
echo "=== bootpd DHCP exchange (last 5m) ==="
log show --predicate 'process == "bootpd"' --last 5m --style syslog 2>/dev/null \
  | grep -iE "DISCOVER|OFFER|REQUEST|ACK|192.168.2" | tail -15 || echo "  (no exchange logged)"

echo ""
echo "=== mDNS: Pi advertising ssh? ==="
dns-sd -B _ssh._tcp > "$TMPF" 2>&1 & P=$!; sleep 5; kill $P 2>/dev/null; wait $P 2>/dev/null
head -8 "$TMPF"; rm -f "$TMPF"

echo ""
echo "=== NAT states (traffic flowing through us?) ==="
pfctl -s state 2>/dev/null | grep 192.168.2 | head -10 || echo "  (none yet)"
