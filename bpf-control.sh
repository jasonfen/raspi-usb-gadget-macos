#!/bin/bash
R="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Can tcpdump on THIS Mac see outbound frames at all?
# If en0 also shows zero outbound, "en7 emits nothing" is an instrument
# artifact of Skywalk BPF, not a finding. Control before conclusion.
OUT="$R"/bpfcheck.txt
: > "$OUT"
exec > >(tee -a "$OUT") 2>&1

for IF in en0 en7; do
  MAC=$(ifconfig $IF 2>/dev/null | awk '/ether/{print $2}')
  [ -z "$MAC" ] && { echo "$IF: no MAC, skipping"; continue; }
  # tcpdump prints MACs without leading zeros in each octet
  SHORT=$(echo "$MAC" | sed 's/\b0\([0-9a-f]\)/\1/g')
  echo "=== $IF (mac $MAC) ==="
  tcpdump -i $IF -n -e -c 60 > "$R"/bpf_$IF.cap 2>"$R"/bpf_$IF.err &
  P=$!
  sleep 3
  if ! kill -0 $P 2>/dev/null; then echo "  tcpdump died:"; cat "$R"/bpf_$IF.err; continue; fi
  if [ "$IF" = "en0" ]; then
    ping -c4 -t1 1.1.1.1 >/dev/null 2>&1
    dig +short +time=1 +tries=1 apple.com >/dev/null 2>&1
  else
    ping -c4 -t1 192.168.2.255 >/dev/null 2>&1
    ping -c4 -t1 10.12.194.1   >/dev/null 2>&1
  fi
  sleep 5
  kill $P 2>/dev/null; wait $P 2>/dev/null
  TOT=$(grep -c . "$R"/bpf_$IF.cap)
  O=$(grep -cE "^[0-9:.]+ $SHORT >" "$R"/bpf_$IF.cap)
  echo "  frames: $TOT   outbound (src=$SHORT): $O"
  [ "$O" -eq 0 ] && echo "  >>> NO outbound visible on $IF"
done
echo ""
echo "INTERPRETATION:"
echo "  en0 outbound > 0 and en7 outbound = 0  -> en7 TX really is dead"
echo "  both 0                                 -> BPF cannot see outbound here;"
echo "                                            every 'nothing sent' claim is void"
