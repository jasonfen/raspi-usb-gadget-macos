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
# Round 2: is the OUT stall a halted dwc2 endpoint or a u_ether requeue bug?
# Discriminator: dwc2 IRQ count sampled alongside rx_packets.
#   IRQ climbing while rx flat  -> controller alive, software never re-arms RX
#   IRQ flat while rx flat      -> controller halted the endpoint
set +e
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
B=/boot/firmware; [ -d /boot/firmware ] || B=/boot
D=$B/diag4.txt
DBG=/sys/kernel/debug/dwc2/3f980000.usb

say() { echo "$@" >> "$D"; sync; }
rx()  { cat /sys/class/net/usb0/statistics/rx_packets 2>/dev/null || echo -1; }
tx()  { cat /sys/class/net/usb0/statistics/tx_packets 2>/dev/null || echo -1; }
irq() { local v
        v=$(grep -iE 'dwc2|3f980000' /proc/interrupts | head -1 \
            | awk '{s=0; for(i=2;i<=NF;i++) if($i ~ /^[0-9]+$/) s+=$i; print s}')
        echo "${v:-0}"; }
dwc() { dmesg -T 2>/dev/null | grep -iE "dwc2|ep_stop_xfr|txfifo|ep[0-9]|gadget|usb0|g_ether|halt|stall|reset|timeout"; }

# dump every readable dwc2 debugfs file, size-capped so a hang cannot eat the run
dbgdump() {
  say "  --- dwc2 debugfs @ $1 ---"
  if [ ! -d "$DBG" ]; then say "  (debugfs absent: $DBG)"; return; fi
  for f in "$DBG"/*; do
    [ -f "$f" ] || continue
    say "  [$(basename "$f")]"
    say "$(timeout 5 head -c 3000 "$f" 2>/dev/null | sed 's/^/    /')"
  done
  for d in "$DBG"/ep*; do
    [ -d "$d" ] || continue
    say "  [ep dir $(basename "$d")]"
    for f in "$d"/*; do
      [ -f "$f" ] && say "    $(basename "$f"): $(timeout 5 head -c 800 "$f" 2>/dev/null | tr '\n' ' ')"
    done
  done
}

: > "$D"
say "===== dwc2 OUT-stall diagnostic, round 2, $(date -u) ====="
say "$(uname -a)"
say ""
say "########## dr_mode (find -L: /proc/device-tree is a symlink) ##########"
for f in $(find -L /proc/device-tree -name dr_mode 2>/dev/null); do
  say "  $f = $(tr -d '\0' < "$f" 2>/dev/null)"
done
say "  usb node compatible: $(tr -d '\0' < /proc/device-tree/soc/usb@7e980000/compatible 2>/dev/null)"
say ""
say "########## dwc2 module params ##########"
for f in /sys/module/dwc2/parameters/*; do
  [ -f "$f" ] && say "  $(basename "$f") = $(cat "$f" 2>/dev/null)"
done
say ""
say "########## debugfs mounted? ##########"
say "  $(mount | grep -i debugfs || echo 'NOT MOUNTED -- attempting')"
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null
say "  $(mount | grep -i debugfs || echo 'still not mounted')"
say "  dwc2 debugfs dir: $(ls -d $DBG 2>/dev/null || echo ABSENT)"
say "  contents: $(ls $DBG 2>/dev/null | tr '\n' ' ')"
say ""
say "########## irq line ##########"
say "  $(grep -i dwc2 /proc/interrupts || echo 'no dwc2 line in /proc/interrupts')"
say ""
say "########## link ##########"
say "  udc state=$(cat /sys/class/udc/*/state 2>/dev/null)"
say "  usb0 mac=$(cat /sys/class/net/usb0/address 2>/dev/null) carrier=$(cat /sys/class/net/usb0/carrier 2>/dev/null) mtu=$(cat /sys/class/net/usb0/mtu 2>/dev/null)"
say ""
dbgdump "t=0 (pre-traffic)"
say ""
say "########## dmesg BEFORE ##########"
say "$(dwc | tail -30)"
say ""

# capture the actual frames arriving on usb0 -- what IS the one packet?
if command -v tcpdump >/dev/null 2>&1; then
  tcpdump -i usb0 -n -e -U -s 128 -w "$B/usb0.pcap" >/dev/null 2>&1 &
  TCPD=$!
  say "########## tcpdump started on usb0 (pid $TCPD) -> usb0.pcap ##########"
else
  say "########## tcpdump NOT INSTALLED -- no frame capture this run ##########"
fi
say ""

say "########## SAMPLING 360s ##########"
say "IRQ climbing + rx flat = software requeue bug.  Both flat = halted endpoint."
say ""
say "$(printf '%-6s %-11s %-11s %-12s %-8s %s' 't(s)' 'rx_packets' 'tx_packets' 'dwc2_irq' 'carrier' 'note')"

PREV_RX=-1; PREV_IRQ=-1; STALL=0; SNAPPED=0
for t in $(seq 0 10 360); do
  R=$(rx); T=$(tx); Q=$(irq); C=$(cat /sys/class/net/usb0/carrier 2>/dev/null)
  DQ=""; [ "$PREV_IRQ" -ge 0 ] 2>/dev/null && DQ="(+$((Q-PREV_IRQ)))"
  if [ "$R" = "$PREV_RX" ]; then STALL=$((STALL+10)); NOTE="rx flat ${STALL}s"
  else STALL=0; NOTE="rx +$((R-PREV_RX))"; fi
  say "$(printf '%-6s %-11s %-11s %-12s %-8s %s' "$t" "$R" "$T" "${Q}${DQ}" "${C:-?}" "$NOTE")"

  # the money shot: snapshot debugfs the moment the stall is established
  if [ "$SNAPPED" -eq 0 ] && [ "$STALL" -ge 40 ]; then
    say ""
    dbgdump "t=${t}s WEDGED (rx flat ${STALL}s)"
    say "  irq line: $(grep -i dwc2 /proc/interrupts)"
    say ""
    SNAPPED=1
  fi
  PREV_RX=$R; PREV_IRQ=$Q
  sleep 10
done

[ -n "$TCPD" ] && kill $TCPD 2>/dev/null
say ""
dbgdump "t=360s (final)"
say ""
say "########## usb0 full statistics ##########"
for f in /sys/class/net/usb0/statistics/*; do
  say "  $(basename "$f") = $(cat "$f" 2>/dev/null)"
done
say ""
say "########## dmesg AFTER ##########"
say "$(dwc | tail -60)"
say ""
say "########## anything logged at all since boot (errors) ##########"
say "$(dmesg -T 2>/dev/null | grep -iE 'error|fail|halt|stall|timeout|reset|overflow|babble' | tail -30)"
say ""
say "########## pcap ##########"
say "  $(ls -la $B/usb0.pcap 2>/dev/null || echo 'no pcap')"
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
