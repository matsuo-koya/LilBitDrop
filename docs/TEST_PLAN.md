# AirBridge v0.1 test plan

## Gate A — USB network

Pass criteria:

- Host PC enumerates a USB network adapter.
- Pi has `10.55.0.1/24` on `usb0`.
- Host can open `http://10.55.0.1:8080/`.

## Gate B — radio preflight

Pass criteria:

- External AR9170 interface appears in `iw dev`.
- `filin -i <iface> --check` reports usable monitor-mode capability.

## Gate C — AWDL

Pass criteria:

- `airbridge-awdl` remains active.
- `awdl0` exists and has IPv6 link-local addressing.
- An Apple device in the AirDrop sheet causes peer activity/neighbors to appear.

## Gate D — AirDrop receive

Pass criteria:

- AirBridge receiver appears in Apple's AirDrop picker when receiving from Everyone/Everyone for 10 Minutes mode.
- A JPEG/HEIC/photo transfer finishes.
- The file appears under `/var/lib/airbridge/incoming`.
- The same file appears immediately in the browser inbox.

## Gate E — formats

Test at least:

- JPEG/HEIC photo
- PNG
- PDF
- ZIP
- short video

Web links and identity-gated payloads are outside v0.1 acceptance criteria.

## Gate F — resilience

- unplug/replug AR9170 dongle
- restart iPhone AirDrop sheet
- restart each systemd service
- reboot Pi with both USB links connected
- transfer 20 small files consecutively

Record `journalctl` logs for every failure.
