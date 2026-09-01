#!/bin/bash
# After booting the Pi with modules-load=dwc2,g_ncm:
#   1. is the gadget now NCM (different macOS driver than AppleUserECM)?
#   2. does TX get past the 161-packet wedge?
#   3. take a DHCP lease from the Pi's shared-mode server and SSH in.
[ "$(id -u)" -ne 0 ] && { echo "run as root"; exit 1; }
BASE=/Users/jason/Documents/projects/raspi

pkill -f arp-responder.py 2>/dev/null

echo "waiting for the gadget interface (up to 150s) ..."
INT=""
for t in $(seq 0 3 150); do
  I=$(networksetup -listallhardwareports 2>/dev/null | awk '/Raspberry Pi USB Gadget/{getline; print $2}')
  if [ -n "$I" ] && ifconfig "$I" >/dev/null 2>&1; then INT="$I"; echo ""; echo "[t+${t}s] $INT up"; break; fi
  printf "."; sleep 3
done
[ -z "$INT" ] && { echo ""; echo "interface never appeared -- is g_ncm present in the kernel?"; \
                   echo "if not, the Pi falls back to g_ether and should still enumerate."; exit 1; }
echo "$INT" > "$BASE/.gadget-if"

echo ""
echo "=== which driver is handling it? ==="
ioreg -p IOService -w0 -r -n "Raspberry Pi USB Gadget" 2>/dev/null \
  | grep -E "AppleUser|IOSkywalk|Control Model|NCM|ECM|$INT" | sed 's/^/  /'
echo "  (AppleUserECM = still ECM, g_ncm did not load)"
echo "  (anything else = NCM took effect)"

echo ""
echo "=== becoming a DHCP client of the Pi's shared-mode server ==="
ifconfig "$INT" inet delete 2>/dev/null
networksetup -setdhcp "Raspberry Pi USB Gadget"

LEASE=""
for t in $(seq 0 3 60); do
  LEASE=$(ipconfig getifaddr "$INT" 2>/dev/null || true)
  [ -n "$LEASE" ] && { echo "[t+${t}s] LEASE: $LEASE"; break; }
  printf "."; sleep 3
done
[ -z "$LEASE" ] && echo "" && echo "  no lease yet"

echo ""
echo "=== TX budget check (the old wedge was exactly 161) ==="
for i in 1 2 3; do
  O=$(netstat -I "$INT" -b 2>/dev/null | awk 'NR==2{print $8}')
  I2=$(netstat -I "$INT" -b 2>/dev/null | awk 'NR==2{print $5}')
  echo "  Ipkts=$I2  Opkts=$O"
  ping -c2 -W600 10.12.194.1 >/dev/null 2>&1
  sleep 3
done
O=$(netstat -I "$INT" -b 2>/dev/null | awk 'NR==2{print $8}')
if [ "${O:-0}" -gt 161 ]; then
  echo "  *** PAST 161 (Opkts=$O) -- NCM FIXED THE WEDGE ***"
else
  echo "  Opkts=$O -- not past 161 yet (may just be low traffic; keep watching)"
fi

echo ""
echo "=== can we reach the Pi? ==="
ifconfig "$INT" | grep -E "inet |status" | sed 's/^/  /'
printf "  ping 10.12.194.1: "
ping -c3 -W1200 -q 10.12.194.1 >/dev/null 2>&1 && echo "REPLY" || echo "no reply"
printf "  ssh port 22:      "
nc -z -G 3 10.12.194.1 22 2>/dev/null && echo "OPEN" || echo "closed"
arp -an | grep "$INT" | grep -v incomplete | sed 's/^/  /'

echo ""
echo "If ssh is open:   ssh pi@10.12.194.1"
echo "Then on the Pi:   journalctl -u rpi-usb-gadget-ics -n 50"
echo "                  nmcli connection show"
echo "                  lsmod | grep -E 'g_ncm|g_ether'"
