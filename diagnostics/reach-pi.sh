#!/bin/bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo root
# The Pi is probably still in shared mode at 10.12.194.1/28.
# Join that subnet as a second address so we can reach it and get a shell.
INT=$(cat $REPO/.gadget-if 2>/dev/null || echo en7)

echo "=== what is the Pi actually sending? (8s capture) ==="
tcpdump -i "$INT" -n -l > /tmp/_cap.$$ 2>&1 & P=$!; sleep 8; kill $P 2>/dev/null; wait $P 2>/dev/null
head -20 /tmp/_cap.$$ | sed 's/^/  /'; [ -s /tmp/_cap.$$ ] || echo "  (wire silent)"; rm -f /tmp/_cap.$$

echo ""
echo "=== adding 10.12.194.2/28 alias on $INT (shared-mode subnet) ==="
ifconfig "$INT" inet 10.12.194.2 netmask 255.255.255.240 alias 2>&1
sleep 2
ifconfig "$INT" | grep "inet " | sed 's/^/  /'

echo ""
echo "=== can we reach the Pi at 10.12.194.1? ==="
if ping -c3 -W900 -q 10.12.194.1 >/dev/null 2>&1; then
  echo "  *** PI REACHABLE at 10.12.194.1 ***"
  echo "  ssh in with:  ssh pi@10.12.194.1"
else
  echo "  no reply"
fi

echo ""
echo "=== ARP: did anything answer on either subnet? ==="
arp -an | grep "$INT" | sed 's/^/  /'

echo ""
echo "=== is the Pi's DHCP server offering us a lease? ==="
echo "  (shared mode = Pi serves DHCP; if so it would answer a request on $INT)"
ipconfig getpacket "$INT" 2>&1 | head -12 | sed 's/^/  /'

echo ""
echo "=== mDNS sweep ==="
dns-sd -B _ssh._tcp > /tmp/_mdns.$$ 2>&1 & P=$!; sleep 5; kill $P 2>/dev/null; wait $P 2>/dev/null
head -8 /tmp/_mdns.$$ | sed 's/^/  /'; rm -f /tmp/_mdns.$$

echo ""
echo "NOTE: the 10.12.194.2 alias is temporary (gone on reboot / ifconfig delete)."
echo "Remove with:  sudo ifconfig $INT inet 10.12.194.2 -alias"
