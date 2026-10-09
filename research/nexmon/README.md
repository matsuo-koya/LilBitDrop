# 内蔵 Wi-Fi（BCM43455 + Nexmon）で AWDL を動かす調査

外付け WL300NU-AG（carl9170）なしで、Pi 4B 内蔵の BCM43455 で filin（AWDL）を動かせるかの調査。
main の構成（外付けアダプタ）には手を入れない。

## 手順1: 構成を変えない調査（2026-10-09）— 結果

| 項目 | 結果 |
|---|---|
| 内蔵チップ | BCM4345/6（= 43455c0）、ドライバ brcmfmac + brcmfmac_cyw、FW 7.45.265（2023-08, Cypress）。標準ではモニターモードなし（managed/IBSS/AP/P2P のみ） |
| 上流 Nexmon（seemoo-lab/nexmon, 2026-09 更新） | 43455c0 の FW パッチは 7.45.154/189/206/234/241 まで。**7.45.265 は対象外** → FW を Nexmon 版に差し替える必要あり。ドライバパッチは 6.6.y まで |
| Kali の Nexmon パッケージ | `firmware-nexmon` 0.2（2025-07）: Pi 4B 用は **7.45.206 の Nexmon パッチ版**（`nexmon.org: 2.2.2-552`）。`brcmfmac-nexmon-dkms` 6.12.2（2025-07）: カーネル 6.12 向け |
| 6.18 でのビルド | そのままでは14エラー（タイマー API の改名、cfg80211 の `radio_idx` 引数追加、SDIO ID 定義なし）。機械的な修正（`brcmfmac-nexmon-dkms-6.12.2-to-6.18.diff`、+17/−11 行）で **brcmfmac.ko のビルドに成功**（vermagic 一致）。**読み込みは未実施** |
| 前例 | OWL の README は「OpenDrop と組み合わせて Raspberry Pi 3 などで AirDrop」と記載。OWL issue #63 では Pi 3B + Nexmon で「カーネル 5.10 では mon0 の HW アドレスが正しく、owl は問題なく動いた」、新しいカーネルでは `unable to set HW address`（MAC が 00:00:…） |

## 未確認で、AWDL の成否を決める点

1. 5GHz（ch44）で**データフレーム**の注入が実際に電波に出るか（rtw88 は管理フレームしか出なかった）。
2. AWDL の時刻合わせ精度（carl9170 0.4% / RTL8822BU 12–21% が閾値外）。
3. ch44 ↔ ch6 の切り替え速度（FullMAC の FW 経由）。
4. filin は監視 IF の MAC を読む → Nexmon の監視 IF で MAC が 0 になる問題（issue #63）が 6.18 で出るか。
5. 内蔵 BT（同じチップ）への影響。

## 次の段階の前提

- wlan0 を監視用にすると Wi-Fi 経由の SSH は使えない → 管理経路は USB（Mac から `ssh koya@10.55.0.1`）か有線 LAN。**先に確認する。**
- 元の FW（`/lib/firmware/cypress/cyfmac43455-sdio.bin` へのリンク）と brcmfmac モジュールを退避し、戻す手順を用意してから入れ替える。
- 送信の確認には外付け WL300NU-AG を受信専用の測定器として使う。

## 出典

- https://github.com/seemoo-lab/nexmon （patches/bcm43455c0, patches/driver）
- https://gitlab.com/kalilinux/packages/firmware-nexmon , https://gitlab.com/kalilinux/packages/brcmfmac-nexmon-dkms （kali/master, fff3190）
- https://www.kali.org/blog/raspberry-pi-wi-fi-glow-up/
- https://github.com/seemoo-lab/owl/blob/master/README.md , https://github.com/seemoo-lab/owl/issues/63
