#!/bin/bash
# Packet-frugal: TX budget is ~161 per enumeration. Spend it on reaching the Pi.
# Capture (free, RX only) runs alongside to reveal the Pi's state.
[ "$(id -u)" -ne 0 ] && { echo "run as root"; exit 1; }
INT=$(cat /Users/jason/Documents/projects/raspi/.gadget-if 2>/dev/null || echo en7)
CAP=/tmp/_shell_cap.txt

budget() { echo "  [Opkts=$(netstat -I "$INT" -b 2>/dev/null | awk 'NR==2{print $8}') / 161]"; }

echo "=== starting passive capture (costs no TX) ==="
: > "$CAP"
tcpdump -i "$INT" -n -e -l >> "$CAP" 2>&1 &
CP=$!

echo "=== static 10.12.194.2/28 (no DHCP churn) ==="
ifconfig "$INT" inet delete 2>/dev/null
ifconfig "$INT" inet 10.12.194.2 netmask 255.255.255.240 2>/dev/null
sleep 2
ifconfig "$INT" | grep -E "inet |status" | sed 's/^/  /'
budget

echo ""
echo "=== listening 25s to learn the Pi's state (no TX) ==="
sleep 25
kill $CP 2>/dev/null; wait $CP 2>/dev/null
echo "  frames: $(grep -cE '^[0-9]{2}:' "$CAP")"
echo "  --- source MACs ---"
grep -oE "^[0-9:.]+ [0-9a-f]{2}(:[0-9a-f]{2}){5}" "$CAP" | awk '{print $2}' | sort | uniq -c | sed 's/^/    /'
echo "  --- addresses the Pi claims ---"
grep -oE "10\.12\.194\.[0-9]+|192\.168\.2\.[0-9]+|169\.254\.[0-9]+\.[0-9]+" "$CAP" | sort | uniq -c | sed 's/^/    /'
echo "  --- protocol mix ---"
for p in "who-has" "Reply" "DHCP" "BOOTP" "ICMP6" "solicitation" "advertisement" "5353"; do
  n=$(grep -ci "$p" "$CAP" 2>/dev/null); [ "${n:-0}" -gt 0 ] && printf "    %-16s %s\n" "$p" "$n"
done
echo "  --- last few frames ---"
tail -6 "$CAP" | sed 's/^/    /'

echo ""
echo "=== reach attempts (each costs packets) ==="
budget
printf "  ping 10.12.194.1: "
ping -c2 -W1200 -q 10.12.194.1 >/dev/null 2>&1 && echo "REPLY" || echo "no reply"
budget
printf "  ssh 10.12.194.1:  "
nc -z -G 3 10.12.194.1 22 2>/dev/null && echo "OPEN  <<< ssh pi@10.12.194.1" || echo "closed"
budget
echo "  --- arp ---"
arp -an | grep "$INT" | grep -v incomplete | sed 's/^/    /'

echo ""
echo "capture saved: $CAP"
