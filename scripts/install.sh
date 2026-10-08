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

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y git curl ca-certificates build-essential pkg-config python3 iw rfkill

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
else
  git -C "$PREFIX/opendrop-rs" pull --ff-only || true
fi

cargo build --release --manifest-path "$PREFIX/opendrop-rs/Cargo.toml"
install -m 0755 "$PREFIX/opendrop-rs/target/release/filin" "$PREFIX/bin/filin"
install -m 0755 "$PREFIX/opendrop-rs/target/release/luftlift" "$PREFIX/bin/luftlift"

install -m 0755 "$REPO_ROOT/scripts/usb-network.sh" "$PREFIX/bin/usb-network.sh"
install -m 0755 "$REPO_ROOT/scripts/preflight.sh" "$PREFIX/bin/preflight.sh"
install -m 0755 "$REPO_ROOT/scripts/status.sh" "$PREFIX/bin/status.sh"
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

# Raspberry Pi OS Trixie provides this package; installation is best-effort
# because the image may already contain it or use another gadget setup.
apt-get install -y rpi-usb-gadget 2>/dev/null || true

systemctl daemon-reload

echo
printf '%s\n' 'AirBridge installed.'
printf '%s\n' "1) Edit $CONF and set WIFI_IFACE to the external AR9170 adapter."
printf '%s\n' '2) Run: sudo /opt/airbridge/bin/preflight.sh'
printf '%s\n' '3) Enable services as documented in README.md'
