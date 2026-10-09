#!/usr/bin/env bash
# Create the LilBitDrop USB Ethernet gadget via configfs.
#
# Two configurations, the host picks the one it has a driver for:
#   c.1 RNDIS + Microsoft OS descriptors: Windows 10/11 binds its inbox
#       RNDIS driver with no manual install.
#   c.2 CDC-ECM: macOS (no RNDIS driver at all) and Linux.
# Each function has its own netdev (lbdrndis0, lbdecm0); both are ports of
# the bridge usb0, which carries 10.55.0.1 and the DHCP server, so the rest of
# the stack does not care which one the host chose.
#
# Requires dtoverlay=dwc2,dr_mode=peripheral (Pi 4: the USB-C port).
set -euo pipefail
source /etc/airbridge.conf

G=/sys/kernel/config/usb_gadget/airbridge

modprobe libcomposite
mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config

if [[ -d "$G" ]] && [[ -n "$(cat "$G/UDC" 2>/dev/null)" ]]; then
  echo "gadget already bound to $(cat "$G/UDC")"
  exit 0
fi

UDC_NAME=""
for _ in $(seq 1 20); do
  UDC_NAME="$(ls /sys/class/udc 2>/dev/null | head -n1)"
  [[ -n "$UDC_NAME" ]] && break
  sleep 0.5
done
if [[ -z "$UDC_NAME" ]]; then
  echo "No USB device controller; add dtoverlay=dwc2,dr_mode=peripheral to config.txt" >&2
  exit 1
fi

# Stable per-board identity, so Windows keeps one adapter across reboots.
SERIAL="$(tr -d '\0' </proc/device-tree/serial-number 2>/dev/null || echo 0000000000000000)"
H="$(printf '%s' "$SERIAL" | sha256sum)"
mac() { printf '02:%s:%s:%s:%s:%s' "$1" "${H:0:2}" "${H:2:2}" "${H:4:2}" "${H:6:2}"; }
DEV_MAC="$(mac 41)"       # Pi side, RNDIS (also the bridge usb0)
HOST_MAC="$(mac 42)"      # PC side, RNDIS
ECM_DEV_MAC="$(mac 44)"   # Pi side, ECM
ECM_HOST_MAC="$(mac 43)"  # PC side, ECM

# Bridge first, so usb-network.sh always finds usb0 whichever port comes up.
# No STP and no forward delay: there is never a loop, and the default 15 s
# learning delay would hold the host's first DHCP requests.
if ! ip link show usb0 >/dev/null 2>&1; then
  ip link add usb0 type bridge stp_state 0 forward_delay 0
fi
ip link set usb0 address "$DEV_MAC"

mkdir -p "$G"
cd "$G"
echo 0x1d6b >idVendor   # Linux Foundation
echo 0x0104 >idProduct  # Multifunction Composite Gadget
echo 0x0100 >bcdDevice
echo 0x0200 >bcdUSB
echo 0x02 >bDeviceClass # Communications

mkdir -p strings/0x409
echo "$SERIAL" >strings/0x409/serialnumber
echo "LilBitDrop" >strings/0x409/manufacturer
echo "LilBitDrop USB Network" >strings/0x409/product

mkdir -p configs/c.1/strings/0x409
echo "RNDIS" >configs/c.1/strings/0x409/configuration
echo 250 >configs/c.1/MaxPower

echo 1 >os_desc/use
echo 0xcd >os_desc/b_vendor_code
echo MSFT100 >os_desc/qw_sign

mkdir -p functions/rndis.usb0
echo "$DEV_MAC" >functions/rndis.usb0/dev_addr
echo "$HOST_MAC" >functions/rndis.usb0/host_addr
echo RNDIS >functions/rndis.usb0/os_desc/interface.rndis/compatible_id
echo 5162001 >functions/rndis.usb0/os_desc/interface.rndis/sub_compatible_id

# ifname only takes a %d pattern before bind (a fixed name is EINVAL).
echo 'lbdrndis%d' >functions/rndis.usb0/ifname

mkdir -p configs/c.2/strings/0x409
echo "CDC-ECM" >configs/c.2/strings/0x409/configuration
echo 250 >configs/c.2/MaxPower

mkdir -p functions/ecm.usb0
echo "$ECM_DEV_MAC" >functions/ecm.usb0/dev_addr
echo "$ECM_HOST_MAC" >functions/ecm.usb0/host_addr
echo 'lbdecm%d' >functions/ecm.usb0/ifname

[[ -e configs/c.1/rndis.usb0 ]] || ln -s functions/rndis.usb0 configs/c.1/
[[ -e configs/c.2/ecm.usb0 ]] || ln -s functions/ecm.usb0 configs/c.2/
[[ -e os_desc/c.1 ]] || ln -s configs/c.1 os_desc/

echo "$UDC_NAME" >UDC
RNDIS_IF="$(cat functions/rndis.usb0/ifname)"
ECM_IF="$(cat functions/ecm.usb0/ifname)"
for port in "$RNDIS_IF" "$ECM_IF"; do
  ip link set "$port" master usb0
  ip link set "$port" up
done
echo "gadget bound to $UDC_NAME (bridge usb0: $RNDIS_IF $DEV_MAC/host $HOST_MAC, $ECM_IF $ECM_DEV_MAC/host $ECM_HOST_MAC)"
