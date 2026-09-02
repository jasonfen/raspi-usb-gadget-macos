#!/bin/bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo root
# TX on the gadget interface stops after ~161 packets. Try to unwedge it.
# Tests, in order: baseline -> interface bounce -> disable offloads -> MTU drop.
INT=$(cat $REPO/.gadget-if 2>/dev/null || echo en7)
[ "$(id -u)" -ne 0 ] && { echo "run as root"; exit 1; }

opkts() { netstat -I "$INT" -b 2>/dev/null | awk 'NR==2{print $8}'; }
readdr() {
  ifconfig "$INT" inet 192.168.2.1 netmask 255.255.255.0 2>/dev/null
  ifconfig "$INT" inet 10.12.194.2 netmask 255.255.255.240 alias 2>/dev/null
  sleep 2
}
probe() {  # send traffic, report whether Opkts moved
  local before after
  before=$(opkts)
  ping -c3 -W600 -S 10.12.194.2 10.12.194.1 >/dev/null 2>&1
  ping -c3 -W600 192.168.2.2       >/dev/null 2>&1
  sleep 1
  after=$(opkts)
  echo "    Opkts $before -> $after  (delta $((after-before)))"
  [ "$after" -gt "$before" ] && return 0 || return 1
}

echo "=== current interface options ==="
ifconfig "$INT" | grep -E "options|inet |mtu"

echo ""
echo "=== TEST 1: baseline ==="
probe && { echo "    >>> TX IS WORKING NOW"; exit 0; } || echo "    wedged"

echo ""
echo "=== TEST 2: bounce the interface (resets TX ring) ==="
ifconfig "$INT" down; sleep 3; ifconfig "$INT" up; sleep 4
readdr
ifconfig "$INT" | grep -E "inet |status"
probe && { echo "    >>> RECOVERED via bounce"; echo "bounce" > /tmp/pi-tx-fix; exit 0; } || echo "    still wedged"

echo ""
echo "=== TEST 3: disable TSO / offloads ==="
for opt in -tso4 -tso6 -tso -lro -rxcsum -txcsum; do
  ifconfig "$INT" $opt 2>/dev/null && echo "    applied $opt"
done
ifconfig "$INT" | grep options
readdr
probe && { echo "    >>> RECOVERED by disabling offloads"; echo "offloads" > /tmp/pi-tx-fix; exit 0; } || echo "    still wedged"

echo ""
echo "=== TEST 4: drop MTU to 1000 ==="
ifconfig "$INT" mtu 1000 2>/dev/null && echo "    mtu set" || echo "    mtu change rejected"
readdr
probe && { echo "    >>> RECOVERED at lower MTU"; echo "mtu" > /tmp/pi-tx-fix; exit 0; } || echo "    still wedged"

echo ""
echo "==============================================="
echo "TX could not be unwedged. Final state:"
ifconfig "$INT" | grep -E "options|inet |mtu|status"
netstat -I "$INT" -b | awk 'NR==2{print "  Ipkts="$5"  Opkts="$8}'
echo ""
echo "This is a host driver fault (AppleUserECM / IOSkywalkLegacyEthernet)"
echo "on macOS 27.0 beta. Nothing on the Pi can fix it."
