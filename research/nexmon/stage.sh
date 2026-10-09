#!/usr/bin/env bash
# Stage (do NOT activate) the Nexmon firmware + driver for the built-in BCM43455.
# Usage: sudo stage.sh <nexmon-fw.bin> <brcmfmac.ko>
#   nexmon-fw.bin: Kali firmware-nexmon cypress/cyfmac43455-sdio-standard.bin (7.45.206 nexmon)
#   brcmfmac.ko:   Kali brcmfmac-nexmon-dkms 6.12.2 + brcmfmac-nexmon-dkms-6.12.2-to-6.18.diff,
#                  built against the running kernel
set -euo pipefail
FW_SRC=$1 KO_SRC=$2
STAGE=/opt/airbridge/research/nexmon
KVER=$(uname -r)
strings "$FW_SRC" | grep -q 'nexmon.org' || { echo "not a nexmon firmware: $FW_SRC" >&2; exit 1; }
[[ "$(modinfo -F vermagic "$KO_SRC" | awk '{print $1}')" == "$KVER" ]] || { echo "module not built for $KVER" >&2; exit 1; }
install -d "$STAGE/orig"
install -m 0644 "$FW_SRC" "$STAGE/cyfmac43455-sdio-nexmon.bin"
install -m 0644 "$KO_SRC" "$STAGE/brcmfmac-nexmon-$KVER.ko"
# Record what is in use now, for rollback.sh.
{
  echo "date=$(date -Is)"
  echo "kver=$KVER"
  echo "fw_alt=$(readlink -f /etc/alternatives/cyfmac43455-sdio.bin)"
  echo "fw_version=$(dmesg | grep -o 'Firmware: BCM4345/6.*' | tail -1)"
} >"$STAGE/orig/state.txt"
sha256sum "$STAGE"/*.bin "$STAGE"/*.ko | tee "$STAGE/SHA256SUMS"
cat "$STAGE/orig/state.txt"
echo "staged in $STAGE (nothing activated)"
