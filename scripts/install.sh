#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX=/opt/airbridge
CONF=/etc/airbridge.conf
DATA=/var/lib/airbridge/incoming
UPSTREAM=https://github.com/ayourtch-llm/opendrop-rs.git
# Upstream commit the LilBitDrop patches (patches/*.patch) were made against.
UPSTREAM_BASE=dccc798
BRANCH=airbridge/tlv-only

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y git curl ca-certificates build-essential pkg-config python3 iw rfkill dnsmasq-base hostapd

# Install Rust only when cargo is absent.
if ! command -v cargo >/dev/null 2>&1; then
  if [[ -x /root/.cargo/bin/cargo ]]; then
    export PATH="/root/.cargo/bin:$PATH"
  else
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
    export PATH="/root/.cargo/bin:$PATH"
  fi
fi

mkdir -p "$PREFIX" "$PREFIX/bin" "$DATA"

if [[ ! -d "$PREFIX/opendrop-rs/.git" ]]; then
  git clone "$UPSTREAM" "$PREFIX/opendrop-rs"
fi
# Build upstream + the LilBitDrop patches (iOS 27 discovery TLVs, data-plane
# grace, pinned-transfer ACK gating, dvzip stored blocks / trailer end). An
# existing $BRANCH is left as is so local work is never overwritten.
if ! git -C "$PREFIX/opendrop-rs" rev-parse --verify -q "$BRANCH" >/dev/null; then
  git -C "$PREFIX/opendrop-rs" checkout -b "$BRANCH" "$UPSTREAM_BASE"
  git -C "$PREFIX/opendrop-rs" -c user.name=airbridge -c user.email=airbridge@localhost \
    am "$REPO_ROOT"/patches/*.patch
else
  git -C "$PREFIX/opendrop-rs" checkout "$BRANCH"
fi

cargo build --release --manifest-path "$PREFIX/opendrop-rs/Cargo.toml"
install -m 0755 "$PREFIX/opendrop-rs/target/release/filin" "$PREFIX/bin/filin"
install -m 0755 "$PREFIX/opendrop-rs/target/release/luftlift" "$PREFIX/bin/luftlift"

install -m 0755 "$REPO_ROOT/scripts/usb-gadget.sh" "$PREFIX/bin/usb-gadget.sh"
install -m 0755 "$REPO_ROOT/scripts/usb-network.sh" "$PREFIX/bin/usb-network.sh"
install -m 0755 "$REPO_ROOT/scripts/preflight.sh" "$PREFIX/bin/preflight.sh"
install -m 0755 "$REPO_ROOT/scripts/status.sh" "$PREFIX/bin/status.sh"
install -m 0755 "$REPO_ROOT/scripts/filin-guard.sh" "$PREFIX/bin/filin-guard.sh"
install -m 0755 "$REPO_ROOT/scripts/radio-setup.sh" "$PREFIX/bin/radio-setup.sh"
install -m 0755 "$REPO_ROOT/scripts/wifi-ap.sh" "$PREFIX/bin/wifi-ap.sh"
install -m 0755 "$REPO_ROOT/web/server.py" "$PREFIX/bin/airbridge-web.py"

if [[ ! -f "$CONF" ]]; then
  install -m 0644 "$REPO_ROOT/config/airbridge.conf" "$CONF"
else
  echo "Keeping existing $CONF"
fi

install -m 0644 "$REPO_ROOT/systemd/airbridge-usb.service" /etc/systemd/system/
install -m 0644 "$REPO_ROOT/systemd/airbridge-awdl.service" /etc/systemd/system/
install -m 0644 "$REPO_ROOT/systemd/airbridge-receiver.service" /etc/systemd/system/
install -m 0644 "$REPO_ROOT/systemd/airbridge-web.service" /etc/systemd/system/
install -m 0644 "$REPO_ROOT/systemd/airbridge-radio.service" /etc/systemd/system/
install -m 0644 "$REPO_ROOT/systemd/airbridge-ap.service" /etc/systemd/system/
for unit in airbridge-awdl airbridge-receiver; do
  install -d "/etc/systemd/system/$unit.service.d"
  install -m 0644 "$REPO_ROOT/systemd/$unit.service.d/"*.conf "/etc/systemd/system/$unit.service.d/"
done

# USB gadget: the board's OTG port (Pi 4: USB-C) in device mode. airbridge-usb
# creates the RNDIS + ECM gadget itself, bridges it as usb0 and serves DHCP
# there. NetworkManager is kept off usb0 with a udev property, never with NM
# config: reloading NM config on a cloud-init/netplan image emptied
# /etc/netplan/90-NM-*.yaml and the Wi-Fi profile was gone at the next boot.
BOOTCFG=/boot/firmware/config.txt
[[ -f "$BOOTCFG" ]] || BOOTCFG=/boot/config.txt
if ! grep -q '^# AirBridge USB gadget' "$BOOTCFG"; then
  printf '\n# AirBridge USB gadget\n[all]\ndtoverlay=dwc2,dr_mode=peripheral\n' >>"$BOOTCFG"
  echo "Added dwc2 peripheral overlay to $BOOTCFG (reboot required)"
fi
install -m 0644 "$REPO_ROOT/config/90-lilbitdrop-usb.rules" /etc/udev/rules.d/
install -m 0644 "$REPO_ROOT/config/91-lilbitdrop-ap.rules" /etc/udev/rules.d/
udevadm control --reload
# Left by earlier versions; removed without reloading NM.
rm -f /etc/NetworkManager/conf.d/90-airbridge-usb.conf

systemctl daemon-reload
systemctl enable airbridge-radio.service airbridge-awdl.service airbridge-receiver.service \
  airbridge-usb.service airbridge-web.service airbridge-ap.service

echo
printf '%s\n' 'LilBitDrop installed.'
printf '%s\n' "1) Edit $CONF and set WIFI_IFACE to the external AR9170 adapter."
printf '%s\n' '2) Run: sudo /opt/airbridge/bin/preflight.sh'
printf '%s\n' '3) Reboot, or: sudo systemctl start airbridge-receiver.service'
