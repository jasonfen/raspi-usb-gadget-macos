#!/bin/bash
R="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Post-boot runbook: wait for the gadget, address it, drive traffic until TX
# wedges, and confirm the wedge -- so the sysdiagnose is taken in the state
# Apple needs. A capture taken before the wedge is worthless.
[ "$(id -u)" -ne 0 ] && { echo "run as root: sudo $0"; exit 1; }
OUT="$R"/sysdiagnose-prep.txt
: > "$OUT"; exec > >(tee -a "$OUT") 2>&1

echo "=== 1. waiting for the gadget interface (up to 150s) ==="
INT=""
for t in $(seq 0 3 150); do
  I=$(networksetup -listallhardwareports 2>/dev/null | awk '/Raspberry Pi USB Gadget/{getline; print $2}')
  if [ -n "$I" ] && ifconfig "$I" >/dev/null 2>&1; then INT="$I"; echo "[t+${t}s] $INT is up"; break; fi
  printf "."; sleep 3
done
[ -z "$INT" ] && { echo; echo "interface never appeared. Replug the cable (USB port, not PWR)."; exit 1; }
echo "$INT" > "$R"/.gadget-if

echo
echo "=== 2. applying addresses ==="
ifconfig "$INT" inet 192.168.2.1  netmask 255.255.255.0   alias 2>/dev/null
ifconfig "$INT" inet 10.12.194.2  netmask 255.255.255.240 alias 2>/dev/null
sleep 2
ifconfig "$INT" | grep -E "inet |ether|status" | sed 's/^/  /'

echo
echo "=== 3. on-link routes (must resolve to $INT, not en0) ==="
netstat -rn -f inet | grep "$INT" | sed 's/^/  /'
RI=$(route -n get 192.168.2.2 2>/dev/null | awk '/interface:/{print $2}')
if [ "$RI" != "$INT" ]; then
  echo "  !! 192.168.2.2 routes via '$RI', not $INT -- addresses did not take."
  echo "  !! Check for a live InternetSharing process: pgrep -x InternetSharing"
  exit 1
fi
echo "  routes OK"

echo
echo "=== 4. driving traffic until TX wedges ==="
PREV=-1; FLAT=0; O=0
for i in $(seq 1 40); do
  ping -c3 -t1 10.12.194.1 >/dev/null 2>&1
  ping -c3 -t1 192.168.2.2 >/dev/null 2>&1
  O=$(netstat -I "$INT" -b | awk 'NR==2{print $8}')
  if [ "$O" = "$PREV" ]; then FLAT=$((FLAT+1)); else FLAT=0; fi
  printf "  Opkts=%-6s %s\n" "$O" "$([ $FLAT -gt 0 ] && echo "flat x$FLAT" || echo "climbing")"
  [ "$FLAT" -ge 4 ] && break
  PREV=$O
done

echo
echo "=== 5. verdict ==="
echo "  final Opkts = $O"
netstat -I "$INT" -b | awk 'NR==2{print "  Ipkts="$5"  Opkts="$8"  Oerrs="$9}'
if [ "$FLAT" -ge 4 ]; then
  echo "  *** TX IS WEDGED. Capture now: ***"
  echo
  echo "      sudo sysdiagnose"
  echo
  echo "  ~5 min, writes /var/tmp/sysdiagnose_*.tar.gz."
  echo "  Do NOT unplug the Pi until it finishes."
  [ "$O" = "161" ] && echo "  (wedged at 161, consistent with all nine prior sessions)" \
                   || echo "  (NOTE: wedged at $O, not 161 -- worth recording, the cap may not be constant)"
else
  echo "  Opkts still climbing after 40 rounds. Not wedged yet -- rerun, or leave it longer."
fi
