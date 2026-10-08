#!/usr/bin/env bash
set -euo pipefail
source /etc/airbridge.conf

echo "== AirBridge preflight =="
echo "Wi-Fi interface: $WIFI_IFACE"
echo "AWDL channel:    $AWDL_CHANNEL"
echo

if ! ip link show "$WIFI_IFACE" >/dev/null 2>&1; then
  echo "ERROR: interface '$WIFI_IFACE' does not exist." >&2
  echo "Available wireless interfaces:"
  iw dev 2>/dev/null | awk '$1=="Interface"{print "  " $2}' || true
  exit 2
fi

rfkill list || true

echo
echo "Running filin capability check..."
/opt/airbridge/bin/filin -i "$WIFI_IFACE" --check

echo
echo "USB gadget/network state:"
ip -brief link show "${USB_IFACE:-usb0}" 2>/dev/null || echo "  ${USB_IFACE:-usb0}: not present yet"

echo
echo "Preflight complete."
