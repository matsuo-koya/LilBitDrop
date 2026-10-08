#!/usr/bin/env bash
set -u
source /etc/airbridge.conf

echo "AirBridge status"
echo "================"
echo
printf '%-22s %s\n' "Wi-Fi interface:" "$WIFI_IFACE"
printf '%-22s %s\n' "AWDL interface:" "$AWDL_IFACE"
printf '%-22s %s\n' "Incoming:" "$INCOMING_DIR"
printf '%-22s %s\n' "Web:" "http://${WEB_BIND}:${WEB_PORT}/"
echo
ip -brief addr show "$WIFI_IFACE" 2>/dev/null || true
ip -brief addr show "$AWDL_IFACE" 2>/dev/null || true
ip -brief addr show "$USB_IFACE" 2>/dev/null || true

echo
for svc in airbridge-usb airbridge-awdl airbridge-receiver airbridge-web; do
  printf '%-24s %s\n' "$svc" "$(systemctl is-active "$svc" 2>/dev/null || true)"
done

echo
find "$INCOMING_DIR" -maxdepth 1 -type f -printf '%TY-%Tm-%Td %TH:%TM  %10s  %f\n' 2>/dev/null | sort -r | head -20
