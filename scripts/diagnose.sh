#!/usr/bin/env bash
# LilBitDrop read-only diagnostics snapshot.
# Never stops/starts services, kills processes, or touches wlan0/wlan1/awdl0 config.
# Usage: scripts/diagnose.sh [OUTPUT_BASE_DIR]   (default: ~/airbridge-diagnostics)
set -u

BASE=${1:-$HOME/airbridge-diagnostics}
OUT="$BASE/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
OPENDROP_DIR=/opt/airbridge/opendrop-rs
[ -r /etc/airbridge.conf ] && . /etc/airbridge.conf
UNITS="airbridge-awdl.service airbridge-receiver.service airbridge-usb.service airbridge-web.service"
SUDO=""
sudo -n true 2>/dev/null && SUDO="sudo -n"

run() { local f=$1; shift; { echo "\$ $*"; "$@"; } >>"$OUT/$f" 2>&1; }

# --- duplicate filin detection (the P0 problem) ---
# pgrep -x matches the binary itself, not sudo/bash wrapper lines.
FILIN_PIDS=$(pgrep -x filin || true)
LUFT_PIDS=$(pgrep -x luftlift || true)
FILIN_N=$(echo "$FILIN_PIDS" | grep -c . || true)
LUFT_N=$(echo "$LUFT_PIDS" | grep -c . || true)
AWDL_MAIN=$(systemctl show -p MainPID --value airbridge-awdl.service)
{
  echo "filin processes: $FILIN_N"; for p in $FILIN_PIDS; do ps -o pid=,ppid=,etime=,args= -p "$p"; done
  echo "luftlift processes: $LUFT_N"; for p in $LUFT_PIDS; do ps -o pid=,ppid=,etime=,args= -p "$p"; done
  echo "airbridge-awdl.service MainPID: $AWDL_MAIN"
  for p in $FILIN_PIDS; do
    [ "$p" = "$AWDL_MAIN" ] || echo "WARNING: filin pid $p is NOT the systemd-managed instance (manual run?)"
  done
  [ "$FILIN_N" -gt 1 ] && echo "WARNING: multiple filin instances -> TAP Io(16)/EBUSY and 9930 status ambiguity"
} >"$OUT/processes.txt" 2>&1

# --- git / config / units ---
run git-opendrop-rs.txt git -c safe.directory=$OPENDROP_DIR -C $OPENDROP_DIR remote -v
run git-opendrop-rs.txt git -c safe.directory=$OPENDROP_DIR -C $OPENDROP_DIR status --branch --porcelain
run git-opendrop-rs.txt git -c safe.directory=$OPENDROP_DIR -C $OPENDROP_DIR log -5 --format='%H %ad %s' --date=iso
cp /etc/airbridge.conf "$OUT/airbridge.conf" 2>/dev/null
run systemd-units.txt systemctl cat $UNITS --no-pager
run systemd-show.txt systemctl show $UNITS -p Id -p ActiveState -p UnitFileState -p Requires -p After \
  -p ExecStart -p DropInPaths -p MainPID -p NRestarts -p ActiveEnterTimestamp --no-pager

# --- network / radio state (read-only) ---
run sockets.txt $SUDO ss -ltnp
run iw.txt iw dev
run iw.txt iw dev "${WIFI_IFACE:-wlan1}" info
run ip.txt ip -s link
run ip.txt ip addr
run bluetooth.txt rfkill
run bluetooth.txt timeout 5 bluetoothctl show

# --- introspection APIs ---
curl -s -m 3 http://127.0.0.1:9930/status >"$OUT/filin-status.json" 2>&1
curl -s -m 3 http://127.0.0.1:9931/status >"$OUT/luftlift-status.json" 2>&1

# --- logs (chanseq TLV debug spam counted, not stored) ---
journalctl -u airbridge-awdl.service -u airbridge-receiver.service --since "-2h" --no-pager 2>&1 \
  | tee >(grep -c 'chanseq TLV decoded' >"$OUT/journal-chanseq-count.txt") \
  | grep -v 'chanseq TLV decoded' >"$OUT/journal-filtered-2h.txt"
grep -cE 'Io\(16\)' "$OUT/journal-filtered-2h.txt" >"$OUT/journal-io16-count.txt"

run system.txt uname -a
run system.txt lsusb
ls -la "${INCOMING_DIR:-/var/lib/airbridge/incoming}" >"$OUT/incoming-ls.txt" 2>&1

# --- summary ---
echo "== LilBitDrop diagnose: $OUT"
cat "$OUT/processes.txt"
for u in $UNITS; do printf '%-28s %s\n' "$u" "$(systemctl is-active $u)"; done
echo "filin   /status: $(cat "$OUT/filin-status.json")"
echo "luftlift/status: $(cat "$OUT/luftlift-status.json")"
ip -s link show "${AWDL_IFACE:-awdl0}" 2>/dev/null | awk '/RX:/{getline; print "awdl0 RX packets:", $2} /TX:/{getline; print "awdl0 TX packets:", $2}'
echo "Io(16) lines in last 2h: $(cat "$OUT/journal-io16-count.txt")"
[ -z "$SUDO" ] && echo "(note: no passwordless sudo; ss -p PIDs omitted)"
exit 0
