#!/usr/bin/env bash
set -euo pipefail
source /etc/airbridge.conf

IFACE="${USB_IFACE:-usb0}"
ADDR="${USB_ADDRESS:-10.55.0.1/24}"

# rpi-usb-gadget or a user-provided gadget config is expected to create usb0.
# Wait for it, then assign a deterministic address.
for _ in $(seq 1 60); do
  if ip link show "$IFACE" >/dev/null 2>&1; then
    ip link set "$IFACE" up
    ip addr replace "$ADDR" dev "$IFACE"
    exec sleep infinity
  fi
  sleep 1
done

echo "Timed out waiting for USB gadget interface $IFACE" >&2
exit 1
