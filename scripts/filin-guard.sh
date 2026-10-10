#!/usr/bin/env bash
# ExecStartPre guard for airbridge-awdl.service.
# 1. Refuses to start when any filin is already running (e.g. a manual `sudo filin ...`),
#    which would otherwise fight over the awdl0 TAP (Io(16)/EBUSY) and port 9930.
#    Runs before the service's own filin exists, so any match is foreign.
# 2. Refuses to start when the AWDL channel is "no IR" on the monitor phy: mac80211
#    silently drops every injected frame there (ieee80211_monitor_start_xmit ->
#    cfg80211_reg_can_beacon), so filin would look healthy but never transmit.
[ -r /etc/airbridge.conf ] && . /etc/airbridge.conf
WIFI_IFACE=${WIFI_IFACE:-wlan1}
AWDL_CHANNEL=${AWDL_CHANNEL:-44}

PIDS=$(pgrep -x filin)
if [ -n "$PIDS" ]; then
  echo "filin-guard: another filin is already running; refusing to start a second one:" >&2
  for p in $PIDS; do ps -o pid=,args= -p "$p" >&2; done
  echo "filin-guard: stop it (Ctrl+C in its terminal) and the service will start on the next retry." >&2
  exit 1
fi

phy_of() { iw dev "$WIFI_IFACE" info 2>/dev/null | awk '/wiphy/{print "phy"$2}'; }

# 3. When the adapter's firmware hangs, carl9170's own restart can fail and leave
#    the USB interface unbound (2026-10-10 10:46: "no command feedback received",
#    "firmware upload failed (-32)", probe error -115). The device stays on the bus,
#    and binding it to the driver again brings $WIFI_IFACE back without a replug.
#    At most one attempt per REBIND_INTERVAL seconds, as this runs every 2 s.
DRIVER=${WIFI_DRIVER:-carl9170}
REBIND_INTERVAL=60
REBIND_STAMP=/run/airbridge/rebind-last
rebind_adapter() {
  local d now last bound=
  now=$(date +%s)
  last=$(cat "$REBIND_STAMP" 2>/dev/null || echo 0)
  [ $((now - last)) -ge "$REBIND_INTERVAL" ] || return 1
  mkdir -p "${REBIND_STAMP%/*}"
  echo "$now" >"$REBIND_STAMP"
  [ -d "/sys/bus/usb/drivers/$DRIVER" ] || modprobe "$DRIVER"
  for d in /sys/bus/usb/devices/*:*; do
    [ -e "$d/driver" ] && continue
    modprobe -R "$(cat "$d/modalias")" 2>/dev/null | grep -qx "$DRIVER" || continue
    echo "filin-guard: $WIFI_IFACE not present; binding unbound ${d##*/} to $DRIVER" >&2
    echo "${d##*/}" >"/sys/bus/usb/drivers/$DRIVER/bind" && bound=1
  done
  [ -n "$bound" ] || return 1
  for _ in $(seq 1 15); do
    [ -n "$(phy_of)" ] && return 0
    sleep 1
  done
  return 1
}

PHY=$(phy_of)
if [ -z "$PHY" ] && rebind_adapter; then
  PHY=$(phy_of)
  echo "filin-guard: $WIFI_IFACE is back on $PHY after rebind" >&2
fi
if [ -z "$PHY" ]; then
  echo "filin-guard: $WIFI_IFACE not present" >&2
  exit 1
fi
CHLINE=$(iw phy "$PHY" info | grep -E "\[$AWDL_CHANNEL\]" | head -1)
case "$CHLINE" in
  *disabled*|*"no IR"*)
    echo "filin-guard: channel $AWDL_CHANNEL on $PHY is not transmit-capable:$CHLINE" >&2
    echo "filin-guard: injected frames would be dropped silently. Fix: modprobe -r carl9170 && modprobe carl9170" >&2
    exit 1 ;;
esac
exit 0
