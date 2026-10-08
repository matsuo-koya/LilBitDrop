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

PHY=$(iw dev "$WIFI_IFACE" info 2>/dev/null | awk '/wiphy/{print "phy"$2}')
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
