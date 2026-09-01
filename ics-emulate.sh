#!/bin/bash
# Emulate macOS Internet Connection Sharing for the rpi-usb-gadget ICS watcher.
# Presents 192.168.2.1 so the Pi flips to "USB Gadget (client)" on its own.
# No bridge involved -> the BRDGADD kernel timeout never comes into play.
set -u

B=/Users/jason/Documents/projects/raspi/backup
mkdir -p "$B"
EXT=en0
LAN=192.168.2.0/24

echo "==> 0. Locate the gadget interface"
SVC="Raspberry Pi USB Gadget"
INT=$(networksetup -listallhardwareports 2>/dev/null | awk '/Raspberry Pi USB Gadget/{getline; print $2}')
if [ -z "${INT:-}" ] || ! ifconfig "$INT" >/dev/null 2>&1; then
  echo "    !! gadget interface not live (got: '${INT:-none}')"
  echo "    Replug the USB cable and run check-gadget.sh first."
  exit 1
fi
echo "    using $INT"

echo "==> 1. Backups"
cp /etc/bootpd.plist "$B/bootpd.plist.pre-ics" 2>/dev/null
cp /etc/pf.conf      "$B/pf.conf.pre-ics"      2>/dev/null

echo "==> 2. Internet Sharing stays OFF (its bridge path is what was broken)"
plutil -replace NAT.Enabled -integer 0 /Library/Preferences/SystemConfiguration/com.apple.nat.plist
sleep 1

echo "==> 3. Put 192.168.2.1/24 on $INT"
networksetup -setmanual "$SVC" 192.168.2.1 255.255.255.0 2>&1
sleep 2
ifconfig "$INT" inet 192.168.2.1 netmask 255.255.255.0 2>/dev/null
sleep 2
# verify it STICKS -- previously an address was applied then stripped within ~1s
OK=0
for i in 1 2 3 4 5; do
  if ifconfig "$INT" 2>/dev/null | grep -q "inet 192.168.2.1"; then OK=$((OK+1)); fi
  sleep 1
done
echo "    address present in $OK/5 checks"
if [ "$OK" -lt 5 ]; then
  echo "    !! address not holding -- something is stripping it. Stopping."
  ifconfig "$INT" | grep -E "inet|status"
  pgrep -x InternetSharing >/dev/null && echo "    (InternetSharing pid $(pgrep -x InternetSharing) is alive -- likely culprit)"
  exit 1
fi
echo "    OK: $(ifconfig "$INT" | grep 'inet ')"

echo "==> 4. DHCP server scoped to $INT ONLY (never on Wi-Fi -- you are on a real LAN)"
cat > /etc/bootpd.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>bootp_enabled</key>
    <false/>
    <key>detect_other_dhcp_server</key>
    <false/>
    <key>dhcp_enabled</key>
    <array>
        <string>$INT</string>
    </array>
    <key>reply_threshold_seconds</key>
    <integer>0</integer>
    <key>Subnets</key>
    <array>
        <dict>
            <key>name</key>
            <string>pi-usb-gadget</string>
            <key>net_address</key>
            <string>192.168.2.0</string>
            <key>net_mask</key>
            <string>255.255.255.0</string>
            <key>net_range</key>
            <array>
                <string>192.168.2.2</string>
                <string>192.168.2.20</string>
            </array>
            <key>allocate</key>
            <true/>
            <key>lease_min</key>
            <integer>3600</integer>
            <key>lease_max</key>
            <integer>86400</integer>
            <key>dhcp_router</key>
            <array>
                <string>192.168.2.1</string>
            </array>
            <key>dhcp_domain_name_server</key>
            <array>
                <string>1.1.1.1</string>
                <string>8.8.8.8</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST
plutil -lint /etc/bootpd.plist
killall bootpd 2>/dev/null && echo "    bootpd restarted" || echo "    bootpd starts on demand"

echo "==> 5. IPv4 forwarding"
sysctl -w net.inet.ip.forwarding=1

echo "==> 6. pf NAT (separate ruleset; /etc/pf.conf untouched)"
cat > /etc/pf.anchors/pi-nat <<ANCHOR
nat on $EXT from $LAN to any -> ($EXT)
ANCHOR
cat > /etc/pf-pi.conf <<'PFCONF'
scrub-anchor "com.apple/*"
nat-anchor "com.apple/*"
nat-anchor "pi-nat"
rdr-anchor "com.apple/*"
dummynet-anchor "com.apple/*"
anchor "com.apple/*"
load anchor "com.apple" from "/etc/pf.anchors/com.apple"
load anchor "pi-nat" from "/etc/pf.anchors/pi-nat"
PFCONF
pfctl -f /etc/pf-pi.conf 2>&1 | grep -viE "altq|could result" || true
pfctl -e 2>&1 | grep -viE "altq" || true

echo "$INT" > /Users/jason/Documents/projects/raspi/.gadget-if

echo ""
echo "===================== RESULTS ====================="
echo "--- $INT ---"; ifconfig "$INT" | grep -E "inet |status"
echo "--- forwarding (want 1) ---"; sysctl -n net.inet.ip.forwarding
echo "--- NAT rule ---"; pfctl -a pi-nat -s nat 2>&1 | grep -viE "altq" || echo "  (none!)"
echo "--- bootpd ---"; pgrep -x bootpd >/dev/null && echo "  pid $(pgrep -x bootpd)" || echo "  not running"
echo "==================================================="
echo ""
echo "Wait 60-90s for the Pi's ICS watcher, then run verify-pi.sh"
