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

## 手順2 準備（2026-10-09 21:04）

- 方針: wlan0 を切り替えると Pi 上の Claude Code（API 通信が wlan0）が止まるため、以後は **Mac 上の Claude Code から USB 経由の SSH** で操作する（`HANDOFF.md`）。
  Mac → `ssh koya@10.55.0.1` のログインはユーザーが確認済み。
- `stage.sh` で `/opt/airbridge/research/nexmon/` に FW と ko を配置（**未有効化**）。元の状態は `orig/state.txt`（FW 7.45.265、alternatives = standard）。
- `enable.sh` / `rollback.sh`: FW は update-alternatives で切り替え（パッケージ更新で勝手に戻らない）、ko は `/lib/modules/$KVER/updates/`。
- CLM blob は Kali 版と同一（`cmp` 一致）なので差し替えない。

## 手順1–2 実施結果（2026-10-09、Mac から USB/SSH 経由）

管理経路: Mac に鍵ペアを作成し `authorized_keys` へ登録（手順0 の鍵認証を確立）。以後 `ssh koya@10.55.0.1` で USB 経由操作。sudo パスワードなし確認済み。

### 手順1: Nexmon 有効化 — **合格**

`sudo enable.sh` 実行。SHA256SUMS 一致、staged ko の vermagic が稼働カーネル（`6.18.50+rpt-rpi-v8 SMP preempt mod_unload modversions aarch64`）と完全一致。

| 判定項目 | 結果 |
|---|---|
| Nexmon FW ロード | ○ `7.45.206 (nexmon.org: 2.2.2-552-gb8c6-2) FWID 01-88ee44ea` |
| brcmfmac | ○ `updates/brcmfmac.ko`（out-of-tree, `taints kernel` のみ） |
| カーネル警告/oops | ○ なし。旧 phy 解放中に `brcmf_cfg80211_get_tx_power: error (-5)` と `reg_notifier: Country code iovar returned err = -5` が各1件出たが、これは旧ドライバ teardown 中の良性ノイズ（新ロード後の FW init はクリーン） |
| wlan0 存在 | ○ 復活し SSID `Mazzotp` へ自動再接続（phy 番号は再読込ごとに振り直し） |
| monitor モード追加 | ○ phy の Supported interface modes に `monitor` が出現（ベースラインには無かった） |

### 手順2: 監視 IF — **不合格**（内蔵チップでは AWDL 不可の結論）

| 基準 | 結果 |
|---|---|
| mon0 作成 | ○ `iw phy <phy> interface add mon0 type monitor` で作成・up 可 |
| MAC 正常 | ✗ **`00:00:00:00:00:00`**。`ip link set mon0 address …` → `RTNETLINK: Operation not supported`（driver が MAC 変更を拒否）＝**OWL issue #63 が 6.18 でも再現** |
| ch44/ch6 設定可 | ✗ `iw dev mon0 set channel` → **`Device or resource busy (-16)`**。FullMAC の単一無線を wlan0 の association（`Mazzotp`, ch48/80MHz）が占有し、副 vif はその ch48 に固定される |
| filin で MAC 指定 | ✗ `filin --help` に MAC/addr/bssid オプションは**無い**（`-i/-c/-h/-N/--pcap/--park/-f/-M/--force-master/--no-force-master/--tx-retransmits/--check` のみ）。filin は監視 IF の MAC を読む設計のため全0 MAC は致命的 |
| wlan0 自体を monitor 化（実 MAC 保持の代替経路） | ✗ `iw dev wlan0 set type monitor` → `Device busy`。`iw dev wlan0 disconnect` + `ip link set wlan0 down` 後も不可。NM 配下の `wpa_supplicant`（pid 763, `-u` D-Bus 制御）が wlan0 を掴み即再接続するため。これを外すには wpa_supplicant 停止が必要で「守ること」（NM に触れない）に抵触 → 不採用 |

**結論**: 内蔵 BCM43455 + Nexmon(7.45.206)/brcmfmac(6.18移植) では、監視 IF の MAC が全0かつ変更不可（issue #63）で、filin に MAC 指定手段も無く、AWDL の送信元 MAC が成立しない。加えて FullMAC 単一無線のチャンネル占有で ch44/ch6 の制御もできない。**rtw88 と同じく内蔵は不可**。手順3–5（送信確認・同期精度・iPhone 試験）は前提を満たさず未実施。

### 後片付け — 完了

`sudo rollback.sh` 実行。stock FW `7.45.265` 復帰、brcmfmac 純正（`updates/` の ko 削除）、phy の monitor モード消失（ベースラインに戻る）、mon0 無し。本番サービス `airbridge-usb/receiver/awdl` すべて active、wlan1 監視 ch44 維持、wlan0 は `Mazzotp` 接続。システムは元の本番状態に復旧。

### 残課題 / 次にやるなら

- issue #63（全0 MAC）を回避するには、監視 vif に MAC を割り当てられる **nexmon 側のパッチ**か、filin に **MAC 明示オプション**を足す改修が要る。どちらも「機械的移植」を超える作業。
- ch 占有は wlan0 を完全に非 associate にすれば解けるが、NM/wpa_supplicant を止める必要があり本番構成と両立しない。
- 当面は外付け carl9170（wlan1）構成を正とする。
