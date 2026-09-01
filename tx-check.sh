#!/bin/bash
# Run this FIRST, always. A wedged TX voids every test that needs to send.
INT=$(cat /Users/jason/Documents/projects/raspi/.gadget-if 2>/dev/null || echo en7)
ifconfig "$INT" >/dev/null 2>&1 || { echo "$INT does not exist -- replug the Pi"; exit 2; }
A=$(netstat -I "$INT" -b 2>/dev/null | awk 'NR==2{print $8}')
ping -c3 -W600 192.168.2.99 >/dev/null 2>&1
sleep 2
B=$(netstat -I "$INT" -b 2>/dev/null | awk 'NR==2{print $8}')
echo "$INT  Opkts $A -> $B  (delta $((B-A)))"
if [ "$B" -gt "$A" ]; then
  echo "TX ALIVE -- $((161-B)) packets of budget left before the 161 wedge"
  exit 0
else
  echo "TX WEDGED at $B -- replug the Pi. Any send-test right now is VOID."
  exit 1
fi
