#!/usr/bin/env bash
# Back to the stock Cypress firmware + in-tree brcmfmac (wlan0 reconnects to
# the saved Wi-Fi profile). Safe to run more than once.
set -uo pipefail
KVER=$(uname -r)
iw dev mon0 del 2>/dev/null
rm -f "/lib/modules/$KVER/updates/brcmfmac.ko"
depmod -a "$KVER"
update-alternatives --auto cyfmac43455-sdio.bin
update-alternatives --remove cyfmac43455-sdio.bin /usr/lib/firmware/cypress/cyfmac43455-sdio-nexmon.bin 2>/dev/null
rm -f /usr/lib/firmware/cypress/cyfmac43455-sdio-nexmon.bin
modprobe -r brcmfmac_cyw brcmfmac 2>/dev/null || modprobe -r brcmfmac
sleep 1
modprobe brcmfmac
sleep 8
modinfo -n brcmfmac
readlink -f /etc/alternatives/cyfmac43455-sdio.bin
dmesg | grep -E 'brcmfmac.*Firmware' | tail -1
nmcli -t -f DEVICE,STATE,CONNECTION dev | grep wlan0
