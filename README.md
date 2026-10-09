# LilBitDrop

A Raspberry Pi proof-of-concept that receives files from Apple's AirDrop on Linux and exposes the received files to a connected PC over USB networking.

> Status: **PoC / experimental**. This project depends on reverse-engineered AWDL/AirDrop implementations and is not affiliated with or endorsed by Apple.

> Formerly *AirBridge*. Internal names (systemd units `airbridge-*`, `/opt/airbridge`, `/etc/airbridge.conf`, `/var/lib/airbridge`) keep the old name for now; the source comments in `patches/` still say "AirBridge".

## What v0.1 does

1. Raspberry Pi appears to a host PC as a USB Ethernet device.
2. An external monitor/injection-capable Wi-Fi adapter participates in AWDL.
3. `opendrop-rs` (`filin` + `luftlift`) receives AirDrop photos/files from an Apple device.
4. Files land in `/var/lib/airbridge/incoming`.
5. The PC opens `http://10.55.0.1:8080/` to download them.

This deliberately avoids presenting a live writable USB mass-storage filesystem, because changing a mounted filesystem behind the host OS risks corruption/cache incoherency.

## Verified so far (2026-10-10)

| What | Result |
|---|---|
| Sender | iPhone Air, iOS 27.2, AirDrop "Everyone for 10 Minutes" |
| Picker | Shows **LilBitDrop** ~11–35 s after boot and stays listed |
| Receive | Photos 0.1–4 MB (JPEG/PNG) saved in about 2–7 s; a re-sent name is saved as `name-1.ext` |
| USB to macOS | iMac (M1) picks CDC-ECM; DHCP, inbox page and download OK |
| USB to Windows | Windows picks RNDIS; DHCP, inbox page and download OK (one other PC/cable pair did not enumerate; not isolated) |
| Boot | All services come up unattended (Pi 4B + NEC WL300NU-AG / carl9170) |

Known limits: powering the Pi from a PC's USB-A port gives under-voltage warnings (transfers still worked); only AR9170/carl9170 adapters are known to work. The Pi 4B's built-in Wi-Fi with Nexmon did not work (monitor interface gets an all-zero MAC); see the `research/nexmon-bcm43455` branch. Step-by-step history: `docs/DIAGNOSTICS.md` (Japanese).

## Recommended PoC hardware

- Raspberry Pi 4 or 5 (Pi 4 is a good first target)
- Raspberry Pi OS 64-bit (Trixie or newer recommended)
- A USB Wi-Fi adapter using **AR9170 / carl9170**, preferably dual-band so channel 44 is available
  - D-Link DWA-160 A1/A2
  - Netgear WNDA3100 v1
  - Netgear WN111 v2
  - TP-Link TL-WN821N v2
  - NEC WL300NU-AG
- USB-C data cable from Pi to host PC
- External power if the host cannot power the Pi reliably

The exact hardware revision matters. Verify USB IDs; many product names were reused with different chipsets.

## Architecture

```text
 iPhone / iPad / Mac
        AirDrop
          │
          ▼
   AR9170 USB Wi-Fi
   monitor + injection
          │
      filin / AWDL
          │ awdl0
          ▼
   luftlift receiver
          │
 /var/lib/airbridge/incoming
          │
  tiny LilBitDrop web UI
          │ HTTP 10.55.0.1:8080
          ▼
 USB Ethernet gadget
          │
    Windows/Linux/macOS
```

## Quick start

### 1. Prepare Raspberry Pi OS

Use Raspberry Pi Imager and enable USB gadget mode if the image offers it. Raspberry Pi OS Trixie images include `rpi-usb-gadget` support on compatible boards.

Boot the Pi normally first and confirm network access.

### 2. Plug in the AR9170 adapter

```bash
lsusb
ip link
```

Find the external Wi-Fi interface name, usually something like `wlan1` or `wlx001122334455`.

### 3. Install LilBitDrop

```bash
git clone <this-repository> airbridge
cd airbridge
sudo ./scripts/install.sh
```

The installer clones and builds upstream `opendrop-rs`, installs LilBitDrop scripts/services, and creates `/etc/airbridge.conf`.

### 4. Configure the Wi-Fi interface

Edit:

```bash
sudo nano /etc/airbridge.conf
```

Set:

```ini
WIFI_IFACE=wlan1
AWDL_CHANNEL=44
USB_ADDRESS=10.55.0.1/24
WEB_PORT=8080
```

### 5. Preflight the Wi-Fi adapter

```bash
sudo /opt/airbridge/bin/filin -i wlan1 --check
```

Replace `wlan1` with the real interface.

### 6. Enable and start

```bash
sudo systemctl enable --now airbridge-usb.service
sudo systemctl enable --now airbridge-awdl.service
sudo systemctl enable --now airbridge-receiver.service
sudo systemctl enable --now airbridge-web.service
```

### 7. Test from iPhone

On iPhone/iPad:

- Settings / Control Center: set AirDrop to **Everyone for 10 Minutes** while testing.
- Share a photo/file with AirDrop.
- Look for the Linux receiver announced by `luftlift`.

On the USB-connected PC, open:

`http://10.55.0.1:8080/`

## Troubleshooting

### The receiver never appears

Check AWDL first:

```bash
sudo journalctl -u airbridge-awdl -f
ip -6 addr show awdl0
ip -6 neigh show dev awdl0
```

Then receiver logs:

```bash
sudo journalctl -u airbridge-receiver -f
```

### Adapter claims monitor mode but transfers fail

Monitor-mode support alone is not enough; frame injection must work for AWDL data frames. The upstream `opendrop-rs` project specifically reports `carl9170` as known-good and warns that some Realtek drivers can advertise monitor capability while silently dropping injected data frames.

### USB network does not appear on the PC

Check:

```bash
ip link show usb0
systemctl status rpi-usb-gadget
systemctl status airbridge-usb
```

Pi 4/5 gadget mode uses the board USB-C port. Power/data topology matters; a weak host port can cause resets.

`airbridge-usb` creates a gadget with two configurations, RNDIS (with Microsoft OS descriptors, so Windows 10/11 binds its inbox driver) and CDC-ECM (macOS, Linux); the host picks the one it has a driver for. Both ports are bridged as `usb0` (10.55.0.1), which hands the PC an address in `10.55.0.10–50` by DHCP. No gateway or DNS is offered, so the PC keeps its own Internet connection.

```bash
systemctl status airbridge-usb
cat /run/airbridge-usb.leases
```

## Security model

v0.1 is intentionally simple:

- Received files are automatically written to a local directory.
- The HTTP server is reachable only over the Pi's interfaces; firewalling is recommended if other interfaces are active.
- The receiver saves each file under its base name only (no `../` or absolute paths) and never overwrites an existing file.
- Filenames are sanitized by the web layer for download and directory traversal is blocked.
- Do not expose port 8080 to the public Internet.

A later revision can add a physical accept button, OLED status, per-transfer approval, and automatic expiration.

## Roadmap

- [x] USB network bridge architecture
- [x] AirDrop receive service wrapper
- [x] Browser file inbox
- [x] systemd integration
- [ ] Physical accept/reject button
- [ ] Status LED / OLED
- [ ] Safer USB mass-storage snapshot export mode
- [ ] BLE advertisement support for Apple receiver discovery / outbound sending
- [ ] Custom CM4/CM5 carrier board
- [ ] Enclosure and PCB

## Licenses

This repository is licensed under GPL-3.0-only (see `LICENSE`).

`opendrop-rs` is a separate upstream GPL-3.0-only project. This installer clones/builds it rather than vendoring its source. The files in `patches/` modify `opendrop-rs` and are distributed under the same GPL-3.0-only terms. Review upstream licensing before redistribution of combined binaries/images.
