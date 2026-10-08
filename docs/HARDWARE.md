# Hardware notes

## PoC target

Use a Raspberry Pi 4 first. It provides:

- USB-C OTG/device mode for the upstream connection to the host PC.
- Separate USB-A host ports for the AWDL Wi-Fi dongle.
- Enough CPU/RAM to compile and run the Rust implementation comfortably.

Pi 5 can also work as a gadget-capable platform, but Pi 4 is a simpler/cheaper PoC target.

## AWDL radio

The current critical constraint is not ordinary Wi-Fi connectivity; it is monitor-mode **frame injection with useful radiotap timestamps**.

Upstream `opendrop-rs` reports Atheros AR9170 with the Linux `carl9170` driver as known-good, particularly on channel 44.

Known AR9170 product names include D-Link DWA-160 A1/A2, Netgear WNDA3100 v1, Netgear WN111 v2, TP-Link TL-WN821N v2, and others. Revisions matter. Confirm the USB ID and chipset before buying.

## Why not the Pi onboard Wi-Fi?

The PoC intentionally does not depend on the onboard Broadcom radio. AirDrop/AWDL requires raw monitor/injection behavior that ordinary station/AP support does not guarantee. Use the radio upstream has actually validated first; optimize later.

## Product direction

After proving the stack, migrate to:

- Compute Module 4/5
- custom carrier with USB device port
- dedicated supported Wi-Fi module/chipset
- physical accept button
- status LED/OLED
- optional internal flash for received files
