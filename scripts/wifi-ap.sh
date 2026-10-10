#!/usr/bin/env bash
# Wi-Fi access point on the built-in radio, for phones that cannot use the USB
# link (e.g. a Pixel): join the "LilBitDrop" network and open the web UI.
#
# brcmfmac (BCM43455) allows one managed + one AP interface on a single
# channel ("#{ managed } <= 1, #{ AP } <= 1, #channels <= 1"), so the AP
# follows whatever channel wlan0 is associated on and wlan0 keeps its home
# Wi-Fi. If wlan0 is not associated, AP_CHANNEL is used.
# The external AR9170 (wlan1, AWDL) is not touched.
#
# The AP interface is unmanaged by NetworkManager via udev
# (91-lilbitdrop-ap.rules); NM's own configuration is not changed or reloaded.
# No router and no DNS are offered, so the phone keeps its mobile data.
set -euo pipefail
source /etc/airbridge.conf

STA="${AP_STA_IFACE:-wlan0}"
IFACE="${AP_IFACE:-uap0}"
ADDR="${AP_ADDRESS:-10.56.0.1/24}"
SSID="${AP_SSID:-LilBitDrop}"
PSK_FILE="${AP_PSK_FILE:-/etc/airbridge-ap.psk}"
RUN=/run/airbridge
mkdir -p "$RUN"

# WPA2 passphrase: generated once, kept out of the world-readable airbridge.conf.
if [ ! -s "$PSK_FILE" ]; then
  # tr gets SIGPIPE when head is done; that is expected, so no pipefail here.
  PSK=$(set +o pipefail; LC_ALL=C tr -dc 'a-km-np-z2-9' </dev/urandom | head -c 12)
  (umask 077; printf '%s\n' "$PSK" >"$PSK_FILE")
  echo "wifi-ap: generated a passphrase in $PSK_FILE"
fi
PSK=$(cat "$PSK_FILE")

CHANNEL=$(iw dev "$STA" info 2>/dev/null | awk '/channel/{print $2; exit}')
CHANNEL="${CHANNEL:-${AP_CHANNEL:-6}}"
if [ "$CHANNEL" -gt 14 ]; then HW_MODE=a; else HW_MODE=g; fi

if ! ip link show "$IFACE" >/dev/null 2>&1; then
  iw dev "$STA" interface add "$IFACE" type __ap
fi
# Own MAC (wlan0's with the locally-administered bit) so clients see a distinct BSSID.
STA_MAC=$(cat "/sys/class/net/$STA/address")
AP_MAC=$(printf '%02x%s' $(( 0x${STA_MAC:0:2} | 0x02 )) "${STA_MAC:2}")
ip link set "$IFACE" down
ip link set "$IFACE" address "$AP_MAC"

CONF="$RUN/hostapd-$IFACE.conf"
(umask 077; cat >"$CONF" <<EOF
interface=$IFACE
driver=nl80211
ssid=$SSID
country_code=${AP_COUNTRY:-JP}
hw_mode=$HW_MODE
channel=$CHANNEL
ieee80211n=1
wmm_enabled=1
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=$PSK
EOF
)
echo "wifi-ap: $SSID on $IFACE ($AP_MAC), channel $CHANNEL (following $STA), $ADDR"

ip addr replace "$ADDR" dev "$IFACE"
NET="${ADDR%/*}"; NET="${NET%.*}"
dnsmasq --keep-in-foreground --conf-file=/dev/null --port=0 \
  --interface="$IFACE" --bind-dynamic --except-interface=lo \
  --dhcp-range="${NET}.10,${NET}.50,255.255.255.0,12h" \
  --dhcp-option=option:router --dhcp-option=option:dns-server \
  --dhcp-authoritative --dhcp-leasefile="$RUN/ap.leases" \
  --log-dhcp &
# hostapd brings the interface up; the address survives that.
exec hostapd "$CONF"
