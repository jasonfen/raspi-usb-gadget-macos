#!/bin/bash
# Run IMMEDIATELY after replugging the Pi.
# Brings up the gateway and starts the ARP responder BEFORE the Pi's first
# probe, so its watcher picks client mode instead of falling back to shared.
[ "$(id -u)" -ne 0 ] && { echo "run as root"; exit 1; }
BASE=/Users/jason/Documents/projects/raspi
LOG="$BASE/responder.log"

pkill -f arp-responder.py 2>/dev/null

echo "waiting for the gadget interface (up to 150s) ..."
INT=""
for t in $(seq 0 3 150); do
  I=$(networksetup -listallhardwareports 2>/dev/null | awk '/Raspberry Pi USB Gadget/{getline; print $2}')
  if [ -n "$I" ] && ifconfig "$I" >/dev/null 2>&1; then INT="$I"; echo ""; echo "[t+${t}s] $INT up"; break; fi
  printf "."; sleep 3
done
[ -z "$INT" ] && { echo ""; echo "interface never appeared"; exit 1; }
echo "$INT" > "$BASE/.gadget-if"

echo "==> addresses"
ifconfig "$INT" -tso 2>/dev/null
ifconfig "$INT" inet 192.168.2.1 netmask 255.255.255.0 2>/dev/null
ifconfig "$INT" inet 10.12.194.2 netmask 255.255.255.240 alias 2>/dev/null
sleep 2
ifconfig "$INT" | grep -E "inet |status" | sed 's/^/    /'

echo "==> forwarding + NAT + dhcp"
sysctl -w net.inet.ip.forwarding=1 >/dev/null
pfctl -f /etc/pf-pi.conf 2>/dev/null; pfctl -e 2>/dev/null
killall bootpd 2>/dev/null
echo "    forwarding=$(sysctl -n net.inet.ip.forwarding)  nat=$(pfctl -a pi-nat -s nat 2>/dev/null | grep -c 'nat on')"

echo "==> ARP responder (must be up before the Pi's first probe)"
python3 "$BASE/arp-responder.py" "$INT" 192.168.2.1 > "$LOG" 2>&1 &
RPID=$!
sleep 2
kill -0 "$RPID" 2>/dev/null || { echo "    FAILED:"; cat "$LOG" | sed 's/^/      /'; exit 1; }
echo "    running (pid $RPID)"

echo ""
echo "=== watching 3 min for the Pi to take a lease ==="
for t in $(seq 0 10 180); do
  R=$(grep -c "replied to" "$LOG" 2>/dev/null)
  L=$(grep -c "192.168.2" /var/db/dhcpd_leases 2>/dev/null)
  D=$(log show --predicate 'process == "bootpd"' --last 30s --style syslog 2>/dev/null | grep -ciE "discover|request|ack")
  printf "  t+%-4ss  arp_replies=%-4s dhcp_pkts=%-4s leases=%s\n" "$t" "${R:-0}" "${D:-0}" "${L:-0}"
  [ "${L:-0}" -gt 0 ] && { echo ""; echo "  *** LEASE ISSUED ***"; break; }
  sleep 10
done

echo ""
echo "=== result ==="
grep -A4 "192.168.2" /var/db/dhcpd_leases 2>/dev/null | sed 's/^/  /' || echo "  no lease"
arp -an | grep "$INT" | grep -v incomplete | sed 's/^/  /'
PI=$(grep -A4 "192.168.2" /var/db/dhcpd_leases 2>/dev/null | grep ip_address | head -1 | cut -d= -f2)
if [ -n "$PI" ]; then
  echo ""
  echo "  Pi is at $PI"
  ping -c3 -W1000 "$PI" 2>&1 | tail -3 | sed 's/^/  /'
  echo "  ssh pi@$PI"
else
  echo ""
  echo "  Still shared-mode. Responder running (pid $RPID)."
  echo "  If it never flips, the watcher needs inspecting on the Pi itself:"
  echo "    journalctl -u rpi-usb-gadget-ics -n 50"
  echo "    nmcli connection show"
fi
