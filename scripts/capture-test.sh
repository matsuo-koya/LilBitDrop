#!/usr/bin/env bash
# Capture everything needed for one iPhone AirDrop attempt (run with sudo).
# Usage: sudo scripts/capture-test.sh [SECONDS]   (default 180)
# Writes ~koya/airbridge-diagnostics/test-<timestamp>/: status JSONL, awdl0 pcap,
# wlan1 pcap of frames NOT sent by us, counters, and journal for the window.
# pcaps contain nearby devices' MACs: keep them local.
set -u
DUR=${1:-180}
[ -r /etc/airbridge.conf ] && . /etc/airbridge.conf
WIFI_IFACE=${WIFI_IFACE:-wlan1}; AWDL_IFACE=${AWDL_IFACE:-awdl0}
SELF=$(cat /sys/class/net/$WIFI_IFACE/address)
OUT=/home/koya/airbridge-diagnostics/test-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"
START=$(date '+%Y-%m-%d %H:%M:%S')
cnt() { echo "$(date +%T) $AWDL_IFACE rx=$(cat /sys/class/net/$AWDL_IFACE/statistics/rx_packets) tx=$(cat /sys/class/net/$AWDL_IFACE/statistics/tx_packets)"; }
cnt >"$OUT/counters.txt"

timeout "$DUR" tcpdump -ni "$AWDL_IFACE" -w "$OUT/awdl0.pcap" 2>"$OUT/tcpdump-awdl0.log" &
timeout "$DUR" tcpdump -ni "$WIFI_IFACE" -w "$OUT/wlan1-others.pcap" "not wlan src $SELF" 2>"$OUT/tcpdump-wlan1.log" &
(
  end=$((SECONDS + DUR))
  while [ $SECONDS -lt $end ]; do
    t=$(date +%s.%N)
    echo "{\"t\":$t,\"filin\":$(curl -s -m 1 http://127.0.0.1:9930/status || echo null),\"luftlift\":$(curl -s -m 1 http://127.0.0.1:9931/status || echo null)}"
    sleep 2
  done
) >"$OUT/status.jsonl" &

echo "capturing ${DUR}s into $OUT — open AirDrop on the iPhone now"
wait
cnt >>"$OUT/counters.txt"
journalctl -u airbridge-awdl.service -u airbridge-receiver.service --since "$START" --no-pager \
  | grep -v 'chanseq TLV decoded' >"$OUT/journal.txt"
chown -R koya:koya "$OUT"
cat "$OUT/counters.txt"
tail -1 "$OUT/status.jsonl"
echo "done: $OUT"
