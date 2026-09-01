#!/bin/bash
# STAGE 1 (runs once via systemd.run in a minimal target).
# Installs a self-removing diagnostic service, restores cmdline, reboots.
set +e
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH

B=/boot/firmware
[ -d /boot/firmware ] || B=/boot
for i in $(seq 1 30); do
  [ -d "$B" ] && touch "$B/.wtest" 2>/dev/null && { rm -f "$B/.wtest"; break; }
  sleep 2; mount -o remount,rw "$B" 2>/dev/null
done

cat > /usr/local/sbin/rpi-usb-diag.sh <<'PAYLOAD'
#!/bin/bash
# Samples usb0 and dmesg while the Mac is connected.
# Writes INCREMENTALLY and syncs after every step, so an early unplug
# still leaves usable data on the FAT partition.
set +e
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
B=/boot/firmware; [ -d /boot/firmware ] || B=/boot
D=$B/diag2.txt

say() { echo "$@" >> "$D"; sync; }
rx()  { cat /sys/class/net/usb0/statistics/rx_packets 2>/dev/null || echo -1; }
tx()  { cat /sys/class/net/usb0/statistics/tx_packets 2>/dev/null || echo -1; }
dwc() { dmesg -T 2>/dev/null | grep -iE "dwc2|ep_stop_xfr|txfifo|ep[0-9]|gadget|usb0|g_ether|reset|timeout"; }

: > "$D"
say "===== dwc2 diagnostic (incremental) $(date -u) ====="
say "$(uname -a)"
say ""
say "########## g_ether.conf ##########"
say "$(cat /usr/lib/modprobe.d/g_ether.conf 2>/dev/null)"
say ""
say "########## /proc/cpuinfo Serial (chroot-stamping theory) ##########"
say "Serial line: $(grep -i '^Serial' /proc/cpuinfo 2>/dev/null || echo 'ABSENT')"
say "awk result:  '$(awk '/^Serial/{print $3}' /proc/cpuinfo 2>/dev/null)'"
say "dt serial:   $(tr -d '\0' < /sys/firmware/devicetree/base/serial-number 2>/dev/null)"
say ""
say "########## udc / link ##########"
say "udc: $(ls /sys/class/udc/ 2>/dev/null)"
for u in /sys/class/udc/*/; do
  say "  state=$(cat $u/state 2>/dev/null) soft_connect=$(cat $u/soft_connect 2>/dev/null)"
done
say "usb0 mac=$(cat /sys/class/net/usb0/address 2>/dev/null) operstate=$(cat /sys/class/net/usb0/operstate 2>/dev/null) carrier=$(cat /sys/class/net/usb0/carrier 2>/dev/null)"
say ""
say "########## dmesg BEFORE ##########"
say "$(dwc | tail -40)"
say ""
say "########## SAMPLING 360s -- keep the Mac plugged in ##########"
say "Pi rx_packets = packets the HOST actually delivered."
say ""
say "$(printf '%-7s %-12s %-12s %-10s %s' 't(s)' 'rx_packets' 'tx_packets' 'carrier' 'note')"

PREV_RX=-1; STALL=0; FROZE=""
for t in $(seq 0 10 360); do
  R=$(rx); T=$(tx); C=$(cat /sys/class/net/usb0/carrier 2>/dev/null)
  NOTE=""
  if [ "$R" = "$PREV_RX" ]; then
    STALL=$((STALL+10)); NOTE="rx flat ${STALL}s"
    [ -z "$FROZE" ] && [ "$STALL" -ge 30 ] && FROZE="$R"
  else
    STALL=0; NOTE="rx +$((R-PREV_RX))"
  fi
  say "$(printf '%-7s %-12s %-12s %-10s %s' "$t" "$R" "$T" "${C:-?}" "$NOTE")"
  # dmesg snapshot every 60s so we catch the moment it wedges
  if [ $((t % 60)) -eq 0 ] && [ "$t" -gt 0 ]; then
    say "  --- dmesg @ t=${t}s ---"
    say "$(dwc | tail -12)"
  fi
  PREV_RX=$R
  sleep 10
done

say ""
[ -n "$FROZE" ] && say ">>> RX FROZE AT $FROZE PACKETS" || say ">>> RX never stalled 30s+"
say ""
say "########## dmesg AFTER (full dwc2/gadget history) ##########"
say "$(dwc | tail -80)"
say ""
say "########## ep_stop_xfr / txfifo_flush (PR#31 signature) ##########"
say "$(dmesg -T 2>/dev/null | grep -iE 'ep_stop_xfr|txfifo_flush|Timeout|failed' | tail -40)"
say "(empty above = the wedge logs nothing, which PR#31 also handles)"
say ""
say "########## ics-watch ##########"
say "$(journalctl -u rpi-usb-gadget-ics -n 60 --no-pager 2>&1 | tail -60)"
say ""
say "########## network ##########"
say "$(ip -br addr 2>/dev/null)"
say "$(ip -s link show usb0 2>/dev/null)"
say "$(nmcli -t connection show 2>/dev/null)"
say "===== end ====="
sync

systemctl disable rpi-usb-diag.service 2>/dev/null
rm -f /etc/systemd/system/rpi-usb-diag.service
rm -f /etc/systemd/system/multi-user.target.wants/rpi-usb-diag.service
systemctl daemon-reload 2>/dev/null
rm -f /usr/local/sbin/rpi-usb-diag.sh
sync
PAYLOAD
chmod 755 /usr/local/sbin/rpi-usb-diag.sh

cat > /etc/systemd/system/rpi-usb-diag.service <<'UNIT'
[Unit]
Description=One-shot USB gadget dwc2 diagnostic (self-removing)
After=multi-user.target network.target
Wants=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rpi-usb-diag.sh
TimeoutStartSec=900
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload 2>/dev/null
systemctl enable rpi-usb-diag.service 2>/dev/null
echo "stage1 ok $(date -u)" > "$B/stage1.log" 2>/dev/null

if [ -f "$B/cmdline.txt.preflight" ]; then
  cp "$B/cmdline.txt.preflight" "$B/cmdline.txt"
  rm -f "$B/cmdline.txt.preflight"
fi
sync
sleep 2
systemctl reboot -f 2>/dev/null || reboot -f 2>/dev/null || echo o > /proc/sysrq-trigger
