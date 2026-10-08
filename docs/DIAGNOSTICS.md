# AirBridge 診断記録

観測事実・測定手順・仮説・再現ログを時系列で記録する。生データ（pcap、MAC入りログ）は
リポジトリに入れず `~/airbridge-diagnostics/<timestamp>/` に置く。

採取は `scripts/diagnose.sh`（読み取り専用。サービス停止・kill・IF設定変更なし）。

---

## Phase 0 — 基準線 (2026-10-08 09:13 JST)

スナップショット: `~/airbridge-diagnostics/20261008-091335/`, `20261008-091521/`

### 環境

| 項目 | 値 |
|---|---|
| kernel | `6.18.50+rpt-rpi-v8` |
| opendrop-rs | `/opt/airbridge/opendrop-rs`, `main` = `origin/main` @ `dccc798` (2026-06-27), 未コミット変更なし, root所有 |
| バイナリ | `/opt/airbridge/bin/{filin,luftlift}` 2026-10-08 07:04 ビルド |
| ファームウェア | `firmware-carl9170 1.9.9-450`, `/lib/firmware/carl9170-1.fw` あり（初期の `-2` エラーは解消済み） |
| `~/airbridge` | インストール済みファイル (`/etc/systemd/system/*`, `/etc/airbridge.conf`, `airbridge-web.py`) と同一。Git化して `main` に v0.1 を基準コミット |
| wlan0 | managed, ch48/80MHz, 192.168.x.x — **変更しない** |
| wlan1 | monitor, ch44 (5220MHz) 20MHz no-HT, MAC `00:3a:9d:xx:xx:xx` |
| awdl0 | UP, MTU 1450, `fe80::23a:9dff:fexx:xxxx/64` |
| Bluetooth | hci0 unblocked, Powered: yes, Discoverable: no |

### サービス

| unit | active | enabled | 備考 |
|---|---|---|---|
| airbridge-awdl | active (PID 12546, 08:12:10〜) | disabled | `filin -i wlan1 -c 44 -h awdl0`（既定 force-master）、drop-inなし |
| airbridge-receiver | active (PID 12645, 08:15:39〜) | disabled | `Requires=airbridge-awdl.service` |
| airbridge-usb / web | inactive | disabled | |

全サービス `disabled` のため、**再起動後は何も自動起動しない**。

### プロセス

採取時点では `filin` 1個（systemd版 12546）、`luftlift` 1個。重複なし。

### 重要: 現在のsystemd版filinが稼働した時刻

ジャーナル（直近2h）に `could not create TAP interface 'awdl0' ... e=Io(16)` が **3996件**。
PID 12546 は 08:12 の起動から **09:07:49 まで約55分間 Io(16) 再試行ループ**にあり、
09:07:50 に `opened TAP host_iface=awdl0` → 09:07:51 `filin links are up` / `force-master enabled`。
つまり手動filinが awdl0 を保持していた間、systemd版は待機していただけで、
手動版終了と同時にsystemd版（force-master）に入れ替わった。

→ ハンドオフ記録 4.6 の「receiverの `Requires=` でsystemd版が起動した」仮説と整合。
→ 09:07:51 以前の 9930 `/status` は手動版のもの。以後はsystemd版（force-master）のもの。

### 基準値（force-master, 単一filin, 09:07:51〜約7分）

| 指標 | 09:13:35 | 09:15:21 |
|---|---|---|
| synced | false | false |
| master_mac | 自分 (`00:3a:9d:xx:xx:xx`) | 自分 |
| aw_alignment_pct | 0 | 0 |
| master_changes | 0 | 0 |
| peer_count | 9 | 8 |
| mdns_rx_self / other | 74 / 0 | 99 / 0 |
| rebroadcast_counts[44] | 401 | 546 |
| awdl0 RX / TX packets | 0 / 84 | 0 / 114 |
| luftlift mdns_query_rx / discover / ask / upload | 0/0/0/0 | 0/0/0/0 |
| luftlift last_announce_ms_ago | 325222 | 450259 |

観察:

- `last_announce_ms_ago` は 09:07:51 の初回（re-）announce からの経過時間とほぼ一致し、
  10秒ごとの `mDNS re-announced (refresh ...)` ログでは更新されていないように見える。
  → **仮説**: このフィールドは初回 announce 時のみ更新。Phase 3 でコード確認する。値だけで広告停止と判断しない。
- force-master では synced=false / alignment 0% が再現（ハンドオフ 4.5 と一致）。

### 未実施（Phase 1 以降）

- `--no-force-master` を systemd 経由で起動し、同条件で比較。
- iPhone 実機を使った試験（時刻・機種・iOS版を記録）。
