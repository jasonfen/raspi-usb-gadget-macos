#!/bin/bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo root
# Applies the gadget addresses, then checks whether macOS actually installs
# on-link routes for them. No route = every packet leaves via the uplink and the Pi
# never sees anything, with no USB fault involved at all.
OUT="$REPO"/evidence/host/routecheck.txt
: > "$OUT"; exec > >(tee -a "$OUT") 2>&1
IF=$(cat "$REPO/.gadget-if" 2>/dev/null)
[ -n "$IF" ] || IF=$(networksetup -listallhardwareports 2>/dev/null | awk '/Raspberry Pi USB Gadget/{getline; print $2}')
echo "=== before ==="
ifconfig $IF | grep -E "inet |ether"
echo "routes via $IF: $(netstat -rn -f inet | grep -c $IF)"

echo "=== applying ==="
ifconfig $IF inet 192.168.2.1 netmask 255.255.255.0 alias
ifconfig $IF inet 10.12.194.2 netmask 255.255.255.240 alias
sleep 2

echo "=== after (addresses must still be here; if they vanish, InternetSharing stripped them) ==="
ifconfig $IF | grep -E "inet "
echo
echo "=== IPv4 routes via $IF ==="
netstat -rn -f inet | grep $IF
echo
echo "=== does 192.168.2.2 route out $IF or out the uplink? ==="
route -n get 192.168.2.2 2>&1 | grep -E "interface|gateway|destination"
echo "=== does 10.12.194.1 route out $IF or out the uplink? ==="
route -n get 10.12.194.1 2>&1 | grep -E "interface|gateway|destination"
echo
echo "VERDICT:"
I1=$(route -n get 192.168.2.2 2>/dev/null | awk '/interface:/{print $2}')
if [ "$I1" = "$IF" ]; then
  echo "  on-link route EXISTS -> traffic is reaching $IF; the stall is real USB"
else
  echo "  *** NO on-link route: 192.168.2.2 goes out '$I1', not $IF ***"
  echo "  *** the Mac never sends to the Pi. No USB fault needed to explain this. ***"
fi
echo
echo "=== generating traffic for the Pi's sampling window ==="
for i in 1 2 3 4 5; do ping -c2 -t1 10.12.194.1 >/dev/null 2>&1; ping -c2 -t1 192.168.2.2 >/dev/null 2>&1; done
echo "Opkts now: $(netstat -I $IF -b | awk 'NR==2{print $8}')"
echo "arp: $(arp -an | grep $IF | tr '\n' ' ')"
