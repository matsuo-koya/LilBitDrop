#!/usr/bin/env bash
set -euo pipefail
source /etc/airbridge.conf

IFACE="${USB_IFACE:-usb0}"
ADDR="${USB_ADDRESS:-10.55.0.1/24}"

# usb-gadget.sh (ExecStartPre) creates usb0. Wait for it, then assign a
# deterministic address.
for _ in $(seq 1 60); do
  if ip link show "$IFACE" >/dev/null 2>&1; then
    ip link set "$IFACE" up
    ip addr replace "$ADDR" dev "$IFACE"
    break
  fi
  sleep 1
done
if ! ip link show "$IFACE" >/dev/null 2>&1; then
  echo "Timed out waiting for USB gadget interface $IFACE" >&2
  exit 1
fi

# DHCP for the host PC. No router and no DNS server are offered, so the PC
# keeps using its own uplink for everything except 10.55.0.0/24.
NET="${ADDR%/*}"; NET="${NET%.*}"
exec dnsmasq --keep-in-foreground --conf-file=/dev/null --port=0 \
  --interface="$IFACE" --bind-interfaces --except-interface=lo \
  --dhcp-range="${NET}.10,${NET}.50,255.255.255.0,12h" \
  --dhcp-option=option:router --dhcp-option=option:dns-server \
  --dhcp-authoritative --dhcp-leasefile=/run/airbridge-usb.leases \
  --log-dhcp
