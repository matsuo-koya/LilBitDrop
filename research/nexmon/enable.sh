#!/usr/bin/env bash
# Switch the built-in Wi-Fi to the staged Nexmon firmware + driver.
# wlan0 (home Wi-Fi) WILL drop. Run it only over the USB link (ssh koya@10.55.0.1)
# and never from a Claude Code running on this Pi (its API traffic goes over wlan0).
# Undo: sudo rollback.sh
set -euo pipefail
STAGE=/opt/airbridge/research/nexmon
KVER=$(uname -r)
( cd "$STAGE" && sha256sum -c --quiet SHA256SUMS )
FW=/usr/lib/firmware/cypress/cyfmac43455-sdio-nexmon.bin
install -m 0644 "$STAGE/cyfmac43455-sdio-nexmon.bin" "$FW"
# Register as an alternative (priority below "standard") and select it by
# hand, so a firmware package update cannot silently swap it back.
update-alternatives --install /usr/lib/firmware/cypress/cyfmac43455-sdio.bin \
  cyfmac43455-sdio.bin "$FW" 5
update-alternatives --set cyfmac43455-sdio.bin "$FW"
install -D -m 0644 "$STAGE/brcmfmac-nexmon-$KVER.ko" "/lib/modules/$KVER/updates/brcmfmac.ko"
depmod -a "$KVER"
modprobe -r brcmfmac_cyw brcmfmac 2>/dev/null || modprobe -r brcmfmac
sleep 1
modprobe brcmfmac
sleep 5
modinfo -n brcmfmac
dmesg | grep -E 'brcmfmac.*Firmware' | tail -1
iw dev
