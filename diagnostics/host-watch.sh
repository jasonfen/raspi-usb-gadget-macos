#!/bin/bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # repo root
L="$REPO"/evidence/host/hostside.txt
: > "$L"
echo "===== host-side counters, en7, $(date -u) =====" >> "$L"
echo "paired with device-side diag2.txt from the dr_mode=peripheral retest" >> "$L"
ifconfig en7 | grep -E "ether|inet |status" >> "$L"
echo "" >> "$L"
printf '%-7s %-9s %-9s %-8s %-8s %s\n' t Ipkts Opkts Ierrs Oerrs note >> "$L"
PREV=-1
for t in $(seq 0 10 400); do
  read -r I O IE OE < <(netstat -I en7 -b | awk 'NR==2{print $5, $8, $6, $9}')
  N=""
  if [ "$O" = "$PREV" ]; then N="Opkts FLAT"; else N="Opkts +$((O-PREV))"; fi
  [ "$PREV" = "-1" ] && N="start"
  printf '%-7s %-9s %-9s %-8s %-8s %s\n' "$t" "$I" "$O" "$IE" "$OE" "$N" >> "$L"
  PREV=$O
  # drive traffic the same way ncm-test.sh does, so a live OUT path shows up
  ping -c2 -t1 10.12.194.1 >/dev/null 2>&1
  sleep 8
done
echo "" >> "$L"
echo "final: $(netstat -I en7 -b | awk 'NR==2{print "Ipkts="$5" Opkts="$8}')" >> "$L"
echo "arp: $(arp -an | grep en7 | grep -v incomplete | tr '\n' ' ')" >> "$L"
echo "===== end =====" >> "$L"
