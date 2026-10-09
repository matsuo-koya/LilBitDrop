#!/usr/bin/env bash
# Oneshot run before airbridge-awdl.service: make sure the AWDL channel is
# transmit-capable on the monitor adapter.
#
# The NEC WL300NU-AG (carl9170, ath EEPROM regdomain 0x88/JP) has come up with
# ch36-48 flagged "no IR" even though the regulatory domain is JP, and mac80211
# then silently drops every injected frame (see docs/DIAGNOSTICS.md).
# Reloading the driver re-applies the JP rules (W52 transmit allowed; W53+ keep
# radar/no-IR). Only the monitor adapter's driver is touched; wlan0 is not.
#
# Usage: radio-setup.sh [CHANNEL]   (default: AWDL_CHANNEL from /etc/airbridge.conf)
set -u
[ -r /etc/airbridge.conf ] && . /etc/airbridge.conf
WIFI_IFACE=${WIFI_IFACE:-wlan1}
AWDL_CHANNEL=${1:-${AWDL_CHANNEL:-44}}
DRIVER=${WIFI_DRIVER:-carl9170}

wait_iface() {
  for _ in $(seq 1 "${1:-30}"); do
    iw dev "$WIFI_IFACE" info >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

chan_line() {
  local phy
  phy=$(iw dev "$WIFI_IFACE" info 2>/dev/null | awk '/wiphy/{print "phy"$2}')
  [ -n "$phy" ] && iw phy "$phy" info | grep -E "\[$AWDL_CHANNEL\]" | head -1
}

chan_ok() {
  local line
  line=$(chan_line)
  [ -n "$line" ] && ! echo "$line" | grep -qE 'disabled|no IR'
}

# The channel flags can lag the interface reappearing after a reload, so poll.
wait_chan_ok() {
  for _ in $(seq 1 "${1:-20}"); do
    chan_ok && return 0
    sleep 1
  done
  return 1
}

if ! wait_iface; then
  echo "radio-setup: $WIFI_IFACE not present" >&2
  exit 1
fi
if chan_ok; then
  echo "radio-setup: ch$AWDL_CHANNEL on $WIFI_IFACE is transmit-capable"
  exit 0
fi

# At most MAX_RELOADS reloads per boot. Back-to-back reloads (3 within ~90 s,
# 2026-10-08) left the WL300NU-AG unable to enumerate on USB (error -71/-110)
# until it was physically replugged. This unit is re-run every time
# airbridge-awdl restarts, so the count lives in /run, not in this process:
# without it a stuck "no IR" would reload the driver every few seconds.
# 2026-10-09 boot: the first reload did not clear "no IR", a second one ~10 s
# later did, so two are allowed.
MAX_RELOADS=2
COUNT_FILE=/run/airbridge/radio-reloads
mkdir -p "${COUNT_FILE%/*}"
reloads=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
if [ "$reloads" -ge "$MAX_RELOADS" ]; then
  if wait_chan_ok; then
    echo "radio-setup: ch$AWDL_CHANNEL transmit-capable"
    exit 0
  fi
  echo "radio-setup: ch$AWDL_CHANNEL still not transmit-capable ($(chan_line | xargs)) and $reloads reloads already done this boot; not reloading again — replug the adapter" >&2
  exit 1
fi
echo $((reloads + 1)) >"$COUNT_FILE"
country=$(iw reg get | awk '/^global/{getline; sub(":", "", $2); print $2; exit}')
echo "radio-setup: ch$AWDL_CHANNEL not transmit-capable ($(chan_line | xargs)); reloading $DRIVER ($((reloads + 1))/$MAX_RELOADS this boot, country ${country:-?})"
[ -n "$country" ] && [ "$country" != "00" ] && iw reg set "$country"
modprobe -r "$DRIVER"
sleep 5
modprobe "$DRIVER"
if wait_iface 60 && wait_chan_ok; then
  echo "radio-setup: ch$AWDL_CHANNEL transmit-capable after reload"
  exit 0
fi
echo "radio-setup: ch$AWDL_CHANNEL still not transmit-capable after reload: '$(chan_line | xargs)'; replug the adapter if it is missing" >&2
exit 1
