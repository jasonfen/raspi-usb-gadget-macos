#!/bin/bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo root
INT=$(cat "$REPO/.gadget-if" 2>/dev/null)
[ -n "$INT" ] || INT=$(networksetup -listallhardwareports 2>/dev/null | awk '/Raspberry Pi USB Gadget/{getline; print $2}')
# Does anything actually leave the gadget interface? Distinguishes a dead TX path from a lying Opkts.
OUT="$REPO"/evidence/host/txprobe.txt
: > "$OUT"
A=$(netstat -I "$INT" -b | awk 'NR==2{print $8}')
echo "Opkts before: $A" | tee -a "$OUT"

tcpdump -i "$INT" -n -e -c 40 > "$REPO"/evidence/host/txprobe.cap 2>"$REPO"/evidence/host/txprobe.err &
P=$!
sleep 3
if ! kill -0 $P 2>/dev/null; then
  echo "!! tcpdump died immediately -- this is a tool failure, NOT a finding:" | tee -a "$OUT"
  cat "$REPO"/evidence/host/txprobe.err | tee -a "$OUT"
  exit 1
fi

echo "-- generating traffic --" | tee -a "$OUT"
ping -c3 -t1 192.168.2.255  >/dev/null 2>&1   # broadcast: no ARP needed
ping -c3 -t1 10.12.194.1    >/dev/null 2>&1   # the Pi in shared mode
ping -c3 -t1 192.168.2.2    >/dev/null 2>&1   # forces a fresh ARP request
sleep 6
kill $P 2>/dev/null; wait $P 2>/dev/null

B=$(netstat -I "$INT" -b | awk 'NR==2{print $8}')
{
  echo "Opkts after:  $B   (delta $((B-A)))"
  echo ""
  echo "=== tcpdump stderr ==="; cat "$REPO"/evidence/host/txprobe.err
  echo "=== frames captured: $(grep -c . "$REPO"/evidence/host/txprobe.cap) ==="
  cat "$REPO"/evidence/host/txprobe.cap
  echo ""
  echo "=== outbound only (src = our MAC 02:00:00:00:00:00) ==="
  grep -c "^.*2:0:0:0:0:0 >" "$REPO"/evidence/host/txprobe.cap
  grep "2:0:0:0:0:0 >" "$REPO"/evidence/host/txprobe.cap | head -10
} | tee -a "$OUT"
echo ""
echo "VERDICT:"
N=$(grep -c "2:0:0:0:0:0 >" "$REPO"/evidence/host/txprobe.cap)
if [ "$N" -gt 0 ] && [ "$B" -eq "$A" ]; then
  echo "  frames ARE leaving; Opkts is a broken Skywalk counter. TX is alive."
elif [ "$N" -eq 0 ]; then
  echo "  nothing outbound. TX path is genuinely dead."
else
  echo "  Opkts moved ($A -> $B). The 161 wedge did not reproduce this run."
fi
