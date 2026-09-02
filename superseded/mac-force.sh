#!/bin/bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo root
# en7 has 02:00:00:00:00:00 while IOKit holds the real IOMACAddress.
# If TX is dead because the BSD interface never got a valid source MAC,
# forcing it should unwedge transmission.
OUT="$REPO"/evidence/host/macfix.txt
: > "$OUT"
exec > >(tee -a "$OUT") 2>&1

REAL=$(ioreg -p IOService -w0 -l -r -n "Raspberry Pi USB Gadget" 2>/dev/null \
       | grep -m1 "IOMACAddress" | grep -oE "<[0-9a-f]{12}>" | tr -d '<>' \
       | sed 's/../&:/g; s/:$//')
echo "IOKit IOMACAddress : $REAL"
echo "en7 before         : $(ifconfig en7 | awk '/ether/{print $2}')"

echo "--- forcing en7 MAC ---"
ifconfig en7 ether "$REAL" 2>&1 || echo "  (set failed)"
sleep 1
echo "en7 after          : $(ifconfig en7 | awk '/ether/{print $2}')"

A=$(netstat -I en7 -b | awk 'NR==2{print $8}')
echo "Opkts before: $A"

tcpdump -i en7 -n -e -c 30 > "$REPO"/evidence/host/macfix.cap 2>"$REPO"/evidence/host/macfix.err &
P=$!
sleep 3
kill -0 $P 2>/dev/null || { echo "!! tcpdump failed to start:"; cat "$REPO"/evidence/host/macfix.err; exit 1; }
ping -c3 -t1 192.168.2.255 >/dev/null 2>&1
ping -c3 -t1 10.12.194.1   >/dev/null 2>&1
sleep 6
kill $P 2>/dev/null; wait $P 2>/dev/null

B=$(netstat -I en7 -b | awk 'NR==2{print $8}')
SELF=$(ifconfig en7 | awk '/ether/{print $2}' | sed 's/0\([0-9a-f]\)/\1/g')
echo "Opkts after : $B  (delta $((B-A)))"
echo "=== frames captured: $(grep -c . "$REPO"/evidence/host/macfix.cap) ==="
cat "$REPO"/evidence/host/macfix.cap
OUTB=$(grep -c "^[0-9:.]* $SELF >" "$REPO"/evidence/host/macfix.cap)
echo ""
echo "outbound frames from us: $OUTB"
echo "VERDICT:"
if [ "$OUTB" -gt 0 ]; then
  echo "  *** TX CAME ALIVE. The dead source MAC was the cause. ***"
else
  echo "  still nothing outbound -- the MAC is not the (only) blocker."
fi
