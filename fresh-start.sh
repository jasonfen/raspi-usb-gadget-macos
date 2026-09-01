#!/bin/bash
# Run IMMEDIATELY after replugging the Pi.
# Disables offloads BEFORE the TX ring has a chance to wedge, then watches
# whether Opkts can get past the ~161 plateau.
[ "$(id -u)" -ne 0 ] && { echo "run as root"; exit 1; }
BASE=/Users/jason/Documents/projects/raspi

echo "waiting for the gadget interface (up to 120s) ..."
INT=""
for t in $(seq 0 3 120); do
  I=$(networksetup -listallhardwareports 2>/dev/null | awk '/Raspberry Pi USB Gadget/{getline; print $2}')
  if [ -n "$I" ] && ifconfig "$I" >/dev/null 2>&1; then INT="$I"; echo "[t+${t}s] $INT is up"; break; fi
  printf "."
  sleep 3
done
[ -z "$INT" ] && { echo ""; echo "never appeared"; exit 1; }
echo "$INT" > "$BASE/.gadget-if"

echo ""
echo "=== disabling offloads FIRST (before any traffic) ==="
ifconfig "$INT" -tso 2>/dev/null
ifconfig "$INT" | grep -E "options|mtu"

echo ""
echo "=== addresses ==="
ifconfig "$INT" inet 192.168.2.1 netmask 255.255.255.0 2>/dev/null
ifconfig "$INT" inet 10.12.194.2 netmask 255.255.255.240 alias 2>/dev/null
sleep 2
ifconfig "$INT" | grep -E "inet |status"

echo ""
echo "=== forwarding + NAT ==="
sysctl -w net.inet.ip.forwarding=1 >/dev/null
pfctl -f /etc/pf-pi.conf 2>/dev/null; pfctl -e 2>/dev/null
echo "  done"

echo ""
echo "=== watching Opkts for 90s (does it pass 161?) ==="
echo "    the Pi ARPs for 192.168.2.1 every ~4s; if we can reply, this climbs"
PREV=0
for t in $(seq 0 5 90); do
  O=$(netstat -I "$INT" -b 2>/dev/null | awk 'NR==2{print $8}')
  I=$(netstat -I "$INT" -b 2>/dev/null | awk 'NR==2{print $5}')
  MARK=""
  [ "${O:-0}" -gt 161 ] && MARK="  <-- PAST 161"
  [ "${O:-0}" -ne "$PREV" ] && MARK="$MARK  (moving)"
  printf "  t+%-3ss  Ipkts=%-6s Opkts=%-6s%s\n" "$t" "$I" "$O" "$MARK"
  PREV=$O
  sleep 5
done

echo ""
echo "=== did the Pi flip to client mode? ==="
arp -an | grep "$INT" | grep -v incomplete | sed 's/^/  /'
grep -A3 "192.168.2" /var/db/dhcpd_leases 2>/dev/null | sed 's/^/  /' || echo "  no lease"
echo ""
O=$(netstat -I "$INT" -b 2>/dev/null | awk 'NR==2{print $8}')
if [ "${O:-0}" -gt 200 ]; then
  echo ">>> TX IS ALIVE (Opkts=$O). Offload disable is the fix -- record it."
else
  echo ">>> STILL CAPPED (Opkts=$O). Offloads are not the cause; driver fault confirmed."
fi
