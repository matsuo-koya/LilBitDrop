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

---

## Phase 1 — systemd 一本化 (2026-10-08 09:20 JST 適用)

適用内容:

- `/opt/airbridge/bin/filin-guard.sh`（ExecStartPre。他の filin が居れば起動拒否）
- `/etc/systemd/system/airbridge-awdl.service.d/10-single-filin.conf`
  （`FILIN_EXTRA_ARGS` 既定 `--no-force-master`、`StartLimitIntervalSec=0`）

手順: receiver/awdl を stop → `pgrep -ax filin` が空を確認 → install → daemon-reload → awdl start → receiver start。

結果（09:21）: `filin` 1個 (PID 14868, `--no-force-master`)、`luftlift` 1個。
起動5秒後 `synced=true`, `aw_alignment_pct=93`, 外部 master, `master_changes=6`, `mdns_rx_other=0`。
filin は ch44/48/6/11 をホップ。**ch149 への切替は毎回 `Io(22)` (EINVAL)** — JP では ch149 は disabled なので想定通り。

---

## 重大発見: 5GHz では注入フレームが1つも送信されていない (09:22〜09:30)

### 観測

`iw phy phy3 info`（carl9170）で ch36/40/44/48 が **`(no IR)`**、52–64 は `no IR, radar detection`。
グローバル/phy#3 の regdomain 表示は JP（5170–5250 は NO-IR なし）にもかかわらず。

### カーネル側のコード（rpi-6.18.y）

- `net/mac80211/tx.c` `ieee80211_monitor_start_xmit()` L2455:
  `if (!cfg80211_reg_can_beacon(wiphy, chandef, iftype)) goto fail_rcu;`
  → `fail_rcu` は `dev_kfree_skb()` して `NETDEV_TX_OK` を返す = **無言で破棄、カウンター無し**。
- `cfg80211_reg_check_beaconing()`（chan.c L1509, bool）は NO_IR チャンネルで false。
- `drivers/net/wireless/ath/regd.c` `ath_regd_init_wiphy()`: EEPROM が world 以外（本機 0x88=JP）
  のとき `ath_default_world_regdomain()` を custom regulatory として適用。この表は
  5150–5350 / 5470–5850 を **`NL80211_RRF_NO_IR`** で定義 → 5GHz 全域が初期 NO_IR。
- `carl9170/main.c` L1988 で非 world なら `regulatory_hint(wiphy, "JP")` を出すが、
  起動時 `cfg80211.ieee80211_regdom=JP`（/proc/cmdline）が先に効いており、
  結果として phy3 の NO_IR が残っている。どの経路で残ったかは未特定（reg.c の strict 置換が
  走れば消えるはずなので、ドライバ再probe時の挙動で検証する）。

### 計測（kprobe、20秒、filin `--no-force-master` 稼働中）

`ieee80211_monitor_start_xmit` 入口 → `cfg80211_reg_check_beaconing(freq)` の戻り値 → `carl9170_op_tx` 到達を1フレームずつ対応付け:

| freq | check | 件数 | ドライバ到達 |
|---|---|---|---|
| 2437 (ch6) | true | 16 | 16 |
| 5180 (ch36) | false | 11 | 0 |
| 5220 (ch44) | false | 51 | 0 |
| 5240 (ch48) | false | 110 | 0 |

（15秒の別計測では入口128件中ドライバ到達13件。journal との時刻突合はクロック差で不正確だったため上の直接計測を正とする）

### 結論

- **ch44/48 上の AWDL アクションフレーム・mDNS・DATA は電波に出ていない。** 2.4GHz ch6 のみ送信される。
- これまで `tcpdump -i wlan1` で見えた自機DATAフレームは、AF_PACKET の送信タップで
  mac80211 が破棄する前にコピーされたもの。ハンドオフ 4.3 の「キャプチャ≠送信」の懸念が的中。
- force-master で `synced=false`/alignment 0% だったのは、自分の同期フレームが誰にも届かないため。
  外部 AWDL DATA が 0 なのも、iPhone 一覧に出ないのも、まずこれで説明できる（BLE 問題は別途残る）。
- JP の電波法上 W52 (ch36–48) は屋内で送信可・DFS 不要。W53 (52–64) は DFS 必須なので NO_IR のままで正しい。
  → 正しい修正は「phy3 に JP ルールを正しく反映させる」こと。規制回避ではない。

### 修正の実施結果 (09:35〜09:40)

1. `sudo iw reg set JP` → phy3 の ch36–48 は **no IR のまま**（変化なし）。
2. サービス停止 → `modprobe -r carl9170 && modprobe carl9170` → wlan1 は **phy4** として再登録、
   ch36/40/44/48 から **no IR が消えた**。ch52 以降は `no IR, radar detection` のまま（正しい）、ch149 disabled。
   wlan0 の接続は維持（アドレス変化なし）。
3. サービス再起動後、同じ kprobe 計測（20秒）:

| freq | check | 件数 | ドライバ到達 |
|---|---|---|---|
| 2437 (ch6) | true | 83 | 83 |
| 5220 (ch44) | true | 24 | 24 |
| 5240 (ch48) | true | 89 | 89 |

→ **5GHz の注入フレームが初めてドライバまで届くようになった。**

修正後1分間（iPhone 操作なし）: `synced=true`, alignment 51–53%, peer 3–5, `master_changes` 14→36（約3秒に1回切替）,
`mdns_rx_other=0`, awdl0 RX=0, luftlift 全カウンター 0。周囲の端末が AirDrop を開いていない状態なので、受信0は想定内。

未解決: なぜ最初の probe 時に NO_IR が残ったかは未特定。**再起動後に再発するかは未検証**。
再発防止として `filin-guard.sh` に「AWDL チャンネルが no IR / disabled なら起動拒否」チェックを追加・インストール済み
（ch44 で exit 0、ch52 指定で exit 1 を確認）。

### 当初の検証計画（参考）

1. `sudo iw reg set JP`（同一 alpha2 の再ヒント）で phy3 のフラグが変わるか。
2. サービス停止 → carl9170 の USB unbind/bind（または `modprobe -r carl9170 && modprobe carl9170`）で
   ドライバヒントを再処理させ、`iw phy phy3 info` の ch36–48 から `no IR` が消えるか。
3. 消えたら同じ kprobe 計測で 5GHz の `carl9170_op_tx` 到達を確認 → force-master / no-force-master を再比較。
4. 恒久化（起動順序・udev 等）は 2 の結果を見て決める。
