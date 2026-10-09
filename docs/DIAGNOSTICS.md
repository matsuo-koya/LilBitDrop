# LilBitDrop 診断記録

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

---

## iPhone 実機試験 #1 (2026-10-08 09:43:20–09:46:20 JST)

- 端末: **iPhone Air / iOS 27.2**、AirDrop「すべての人（10分間）」、写真の共有シートで AirDrop を開いた。
- 構成: 5GHz 送信修正後、filin `--no-force-master` 単一、luftlift `luftlift-15559`、flags 136 (0x88)。
- 採取: `~/airbridge-diagnostics/test-20261008-094320/`（`capture-test.sh 180`）
- **結果: iPhone の一覧に表示されず。**

### 観測（Gate C 初達成）

- awdl0 RX 0 → **14**（プロジェクト初の外部受信）。luftlift `discover_count=1`、`ask_count=0`。
- iPhone の AWDL MAC `92:xx:xx:xx:xx:xx`（IPv6 `fe80::90xx:xxff:fexx:xxxx` から導出）。
  3分間、AWDL Action を 118 件（ブロードキャスト）+ 3 件（自機宛）送信。
- iPhone → 自機のデータフレームは **09:44:22 の 14 件のみ（ch48, MCS1）= awdl0 RX 14 と完全一致** → filin の取りこぼしなし。
- iPhone からの mDNS マルチキャスト（`33:33:00:00:00:fb`）は **0 件**。luftlift `mdns_query_rx=0`。
  iPhone は自機の能動的な mDNS 再告知でこちらを見つけたと考えられる。
- awdl0 上の TCP 8771（1セッションのみ）:
  SYN/SYN-ACK → ClientHello 約1.5KB → ServerHello 657B → クライアント Finished → Discover POST 約4.2KB
  （SenderRecordData 入り plist と推定）→ 応答 269B（TLS 込み）→ サーバ FIN → iPhone RST。以後再接続なし。
- 応答内容は上流と同じ `{ReceiverComputerName, ReceiverModelName, ReceiverMediaCapabilities}`（ReceiverRecordData なし）。

### 解釈（仮説）

- 無線/AWDL/IPv6/TCP/TLS は双方向に成立した。残る問題は **AirDrop アプリケーション層**で、
  iPhone が Discover 応答を受け取った上で送信先として採用しなかった。
- 上流 opendrop-rs の動作確認は **iOS 18.6.2** まで（`docs/airdrop-protocol.md`）。iOS 27.2 で
  受信側に求める条件（例: ReceiverRecordData、TXT flags、HTTP 形式）が変わった可能性がある。**未検証。**
- `luftlift --help` の flags 説明（0x06）は古く、実装の既定 0x88 は上流コミット `b7cb173` で意図的に変更されたもの。

### 次の切り分け候補

1. 旧 iOS/macOS（iOS 18 以前）の端末があれば同条件で試し、iOS バージョン依存かを切り分ける。
2. luftlift の受信ログを詳細化（RUST_LOG=debug / `/trace`）し、Discover 要求のヘッダーと plist キー名、
   応答 HTTP 全体を記録する（SenderRecordData の中身は個人情報なので保存しない）。
3. 共有シートの開閉を繰り返したとき Discover が何回来るかを記録する。

## iPhone 実機試験 #2 (2026-10-08 09:47–09:48 JST) — 一覧表示・転送開始に成功

試験 #1 の採取終了後、ユーザーが再度共有シートを開いたところ **`luftlift-15559` が iPhone の一覧に表示され、送信操作で受信した**（ユーザー報告）。

- luftlift: `discover_count=3`, `ask_count=1`, `upload_count=1`, `last_peer="Air iPhone"`。awdl0 RX 3140 / TX 2895 パケット。
- 09:48:13 Ask（`file_count=1`）を自動承認 → 09:48:20 Upload。
- **しかしファイルは保存されず**: `cpio: stopping, short data field pos=197 filesize=4000944` → `Upload complete count=0`。
  incoming は空。dvzip のブロック解凍エラーのログは無く、`dvzip_to_cpio` のループが
  `block_len == 0 || pos + block_len > data.len()` で黙って終了したとみられる（本文の途中切れ、または iOS 27 で形式が変化）。
- → Gate D（一覧表示）達成、Gate E（保存）未達。
- 対応: receiver に `LUFTLIFT_DUMP_UPLOAD=/var/lib/airbridge/upload-dumps`（root 700）の drop-in を追加し、
  生の Upload 本文を保存して形式を解析する（`systemd/airbridge-receiver.service.d/20-dump-upload.conf`）。

## 「一瞬表示されて消える」(09:52) と filin ピアタイムアウト

- 09:52:55 Discover 1回 → iPhone 一覧に一瞬表示 → 消えた（ユーザー報告）。
- filin ログ: iPhone (`92:xx:xx:xx:xx:xx`) が **09:44〜09:53 で 74 回 evict**、2〜5秒おきに削除→再登録。
- filin-rs `peers::PEER_TIMEOUT_US = 2_000_000`（owl 由来）。ホップ1周期 `HOP_CYCLE_US` ≈ 1.05 s。
  非ピア宛ての送信は `DataSendDecision::Drop`、非ピアからのデータ受信は `drop data frame from non-peer`
  → evict 中は双方向の通信が捨てられ、AirDrop セッションが途切れる。
- 対応: `/opt/airbridge/opendrop-rs` ブランチ `airbridge/peer-timeout` で **10 s に変更**、
  `cargo build --release -p filin-rs`（差分 38 s）、peers テスト 11 件 pass。
  旧バイナリは `/opt/airbridge/bin/filin.orig-2s`。09:56:41 に入れ替え、receiver 名 `luftlift-18387`。

## 修正版 filin (peer timeout 10s) での試験 (09:56–10:05)

- iPhone の evict: **09:56:41〜10:04 で 1 回**（修正前は約9分で74回）。ピア維持は改善。
- しかし Discover **0 回**（luftlift-18387 起動後 約9分）。ユーザー報告「表示されない」。
- 採取 `test-20261008-100227`（3分、共有シートを30秒ごとに開閉）: iPhone は AWDL Action 194 件（ch44 中心）、
  **データフレーム 0 件**（mDNS マルチキャストの問い合わせ・告知を一切送っていない）。

### iOS 27.2 の iPhone は AWDL Service Response TLV でサービスを告知している

`tools/awdl_tlv.py` / `tools/awdl_sr.py` で iPhone の Action フレームの TLV を分解:

- 常時: type 4,5,6,7,12,16(Arpa: UUID 形式ホスト名),17,18,21,23,24,33。
- **type 2 (Service Response) が 1 フレーム平均約6個**。内容:
  - `_applicationservicepairing` / `_appsvcprepair` の PTR → "Air iPhone"
  - 同 SRV（ホスト名 = Arpa の UUID、ポート）
  - 同 TXT: `sn=com.apple.sharingd.AirDrop`, `sid=<UUID>`, `at=<hex>`, `dnm=Air iPhone`
  - `_asquic` の PTR/SRV/TXT（17 フレーム）
- iPhone 自身は `_airdrop._tcp` を告知していない（上流 iOS 18 メモと異なる）。

filin が送る TLV は 4/5/6/7/12/16/18/… で **type 2 を一切送っていない**。
自機の `_airdrop._tcp` は awdl0 上の mDNS マルチキャスト（データフレーム）だけで、iPhone の待受窓・
チャンネルに偶然合ったときしか届かない → 発見が確率的（起動後 3.5〜6 分で1回、または来ない）という観測と整合。

**仮説**: Apple 純正の受信機は `_airdrop._tcp` の PTR/SRV/TXT を自分の MIF の Service Response TLV で告知しており、
iOS 27 の送信側は主にこれで受信機を見つける。filin に `_airdrop._tcp` の type 2 TLV 送信を実装すれば発見が安定する可能性。
TLV 内部の名前圧縮（`c0 0a` など）とレコード形式は未解読 → Wireshark の AWDL dissector (tshark) で確認する。

## 発見の A/B と初の受信成功 (10:31–11:14)

filin のバージョン別（`/opt/airbridge/bin/filin.*` に保存）:

| 版 | 内容 | 結果 |
|---|---|---|
| `filin.orig-2s` | 上流そのまま | Discover は来るが数分に1回、一覧に「一瞬」表示 |
| `filin.peer10s` | peer timeout 10s | 約8分 Discover 0 |
| `filin.svc-elect10s` | +Service Response TLV | Discover 0（iPhone/Mac とも非表示） |
| `filin.svc-elect2s` | +election のみ 2s | Discover 0 |
| `filin.tlv-only` | 上流 + Service Response TLV | **すぐ表示・表示が持続**。Ask まで到達、Upload 中に切断 |
| `filin.tlv-grace`（現行） | tlv-only + 退去ピアのデータ猶予 10s | **小さい写真の受信に成功** |

- ピアテーブル自体の保持を 10s にすると発見できなくなる（原因未特定）。テーブル/選出は owl の 2s のまま、
  データ面（unicast TX ゲート、RX 受理、カーネル近隣エントリ）だけ 10s 猶予する方式にした。
- `/opt/airbridge/opendrop-rs` ブランチ `airbridge/tlv-only`: `fbb798f`（TLV）, `c7fb6c1`（データ猶予）。
  `airbridge/peer-timeout` ブランチは不採用の試行。

### 11:13 iPhone → Pi 受信成功（Gate E: 小ファイル）

- `IMG_1612.jpg` 103,327 バイト（Ask の FileSize と一致）、JPEG 1260×1266、SOI/EOI 正常。
  `/var/lib/airbridge/incoming/IMG_1612.jpg`。iPhone 表示「送信済み」。
- Upload 本文 78,275 バイト = dvzip 4 ブロック（43/66/78112/…）→ 正常に展開。

### 未解決: 大きいファイル

- 11:08 `IMG_1610.jpg` 5,150,752 B: TCP で 5,123,639 B 受信後、**iPhone 側が 11:09:00 に送信を停止**（Pi は全 ACK 済み、
  受信窓 2.8 MB、iPhone の evict なし、Pi は ch44 固定・synced）。約 150 KB/s。iPhone に一瞬エラー表示。
- 10:57 `IMG_1611.jpg` 6,351,001 B: 同様に途中停止（このときは 2s evict によるデータ破棄あり）。
- 09:48 約 4 MB: 7 秒で Upload 完了したが dvzip→cpio で `short data field`（形式または本文途中切れ、ダンプ無し）。
- 仮説: スループット不足（ホップ中の iPhone 滞在チャンネルとの重なり不足）で iOS が打ち切る。要計測。

## 大きい写真の受信成功 (12:01) と、そこまでの修正 (11:15–12:01)

### 発見は全版で「約2分おき」だった（訂正）
11:28 以降の全版で Discover は約2分おきに来ており、picker 表示は短時間で消える。単発試験で
「この版は表示されない」と判断していたのはタイミングの偶然で、版ごとの A/B 判定の一部は信頼できない。
ただし `ackfix`（全 unicast を実チャンネルで判定）は 5 分間 Discover 0 で、範囲を絞った版に置き換えた。

### 修正一覧（`/opt/airbridge/opendrop-rs` ブランチ `airbridge/tlv-only`）
| commit | 内容 | 根拠 |
|---|---|---|
| `114bad1` filin | transfer pin 中、pin 先 peer への unicast を実際の無線チャンネルで判定 | 送信ゲートが採用中の master 系列で判定し TCP ACK が約0.4秒保留→約150 KB/s |
| `48011d9` luftlift | dvzip の stored block（長さ最上位ビット）を解凍せずそのまま連結 | 2.9 MB 本文の実データ: zlib 16 + stored 9 ブロック、`0x80020000` |
| `6aca122` luftlift | リクエストヘッダのログ、30 秒 read timeout、chunk 読み取り失敗時の進捗ログ | 調査用 |
| `3796ad5` luftlift | dvzip 本文を cpio `TRAILER!!!` で終端とみなす、`LUFTLIFT_INSTANCE` | iOS 27 が chunked の last-chunk `0\r\n\r\n` を送らず iPhone 側は「辞退」 |

- receiver drop-in `30-stable-name.conf`: 受信機名 `AirBridge`、mDNS インスタンス `airbridge`（再起動ごとの幽霊表示対策）。

### 結果
- 12:01:28 Upload 開始 → 12:01:35 完了（**約7秒**）。`dvzip body ended at cpio trailer (no last-chunk yet) chunks=83 bytes=3717611`。
- `IMG_1580.jpg` 3,723,276 B（Ask の FileSize と一致）、JPEG 5712×4284、Exif iPhone Air / 27.2。iPhone 表示「送信済み」。
- **Gate E 達成（3.7 MB 写真）。**

### 残課題
- picker 表示が短時間で消える／約2分おきにしか Discover が来ない（発見の安定性）。
- 再起動耐性: carl9170 の NO_IR（要ドライバ再読込）、サービス disabled。
- `upload-dumps`（写真・送信者証明書を含む）の drop-in 撤去とファイル削除。
- Gate F（USB gadget + Web UI）、Gate G（連続転送・再起動）。

## 後片付けと再起動対策 (12:05–12:20)

- `20-dump-upload.conf` を撤去（`systemd/optional/` へ移動）、`/var/lib/airbridge/upload-dumps` と作業コピーを削除。
- `airbridge-radio.service`（oneshot, `scripts/radio-setup.sh`）: 起動時に AWDL チャンネルが送信可能か確認し、
  `no IR` ならドライバ再読込を **1 回だけ** 行う。awdl drop-in に `Wants=/After=airbridge-radio.service`。
- **事故記録**: 再読込経路を ch52（常に no IR）で試験し、約 90 秒で 3 回連続 `modprobe -r/modprobe` したところ
  WL300NU-AG が USB 再列挙に失敗（`error -71/-110`, `unable to enumerate USB device`）。hub 1-1 の
  `authorized` 0→1 では復旧せず、物理的な抜き差しで復旧。→ 再読込は1回に制限。
- 抜き差し後の phy7 は最初から ch36–48 が送信可能（no IR なし）。朝の状態との差は未解明。
- `airbridge-radio/awdl/receiver` を **enable**（usb/web は未）。起動順 radio → awdl → receiver を確認。
- `patches/0001-0008`: `/opt/airbridge/opendrop-rs` の `airbridge/tlv-only`（upstream `dccc798` 起点）を
  format-patch。`git archive` + `git am` で適用するとブランチと完全一致することを確認。
  `install.sh` は `dccc798` から `airbridge/tlv-only` を作ってパッチを適用し、新スクリプト・unit・drop-in を入れて enable する。
- **未検証: 実機の再起動**（Claude Code が Pi 上で動いているため、再起動はユーザーのタイミングで行う）。

## 再起動テスト (12:16) と起動順序の循環

- `airbridge-radio`: 起動直後 ch44 が `no IR` → carl9170 を1回再読込 → 7秒で送信可能に。**再起動で NO_IR は再発する**ので radio-setup は必須。
- `airbridge-awdl` は起動したが **`airbridge-receiver` は起動されなかった**。
  `airbridge-awdl` の `After=multi-user.target` と、receiver の `WantedBy=multi-user.target` + `After=airbridge-awdl` が循環し、
  systemd が `Job airbridge-receiver.service/start deleted to break ordering cycle` で receiver を落とした。
- 修正: awdl を `After=network.target NetworkManager.service` に（`d439d6e`）。修正版 unit 一式で
  `systemd-analyze verify default.target` に循環が出ないことを確認。手動 start 後 12:32 に `IMG_1582.jpg`（2.87 MB）受信。
- **未検証: 修正後の実機再起動。**

## 発見の安定性: 調査メモ (12:35–)

- 告知（Service Response TLV）は 12:28 に1回設定されたきり（`sui=1`）。途中で消えたり変わったりしていない。
- 同期先マスターの入れ替わりが激しい: 約20分で `master_changes` 421回、周囲の 8 台の間で数秒ごとに切替。
  `peer table cleaned` 476回（`PEER_TIMEOUT_US` 2s）。iPhone の chanseq は16スロット中4スロットしか AWDL に居ない
  （`[48,0,44,0,0,0,0,0,6,0,44,0,...]`）ので、2s では表から落ちやすい。切替のたびに自機の時刻・chanseq が変わるのが
  一覧から消える原因の候補。ただしピア表 10s は以前「発見されなくなった」ため、実機試験なしには変えない。
- **ch149 の無駄**: `ensure_social_coverage` が ch149 を自機 chanseq に注入するが、このアダプター（JP）では ch149 は disabled。
  `failed to switch monitor channel err=Io(22) channel=149` が毎周期出る。告知上は「そのスロットは ch149 に居る」ことになり、
  iPhone（chanseq に 149 なし）はそのスロットで自機に送らない。mDNS 再告知も ch149 で 177 回空振り。
  `is_no_ir_channel` は 52–64/100–144 のハードコードで、disabled の 149 を考慮していない。
- 次: (1) ch149 を使えないチャンネルとして扱い 44 で埋める修正、(2) 共有シートを開いたまま 3 分の採取で、
  一覧に出た/消えた時刻とマスター切替・Discover・TCP の対応を取る。

### ch149 修正 (12:44)
- `patches/0009`（opendrop-rs `dc82351`）: SET_CHANNEL が EINVAL を返したチャンネルを実行時に「使用不可」として記録し、
  注入・null 埋め・No-IR 置換先・mDNS 再告知の対象から外す（ch149 が使える地域では従来どおり）。テスト 232 件 pass。
- 12:44 に入れ替え（旧版 `/opt/airbridge/bin/filin.pre-ch149`）。起動後1回目の失敗で ch149 を除外し、
  以後の自機 chanseq は 6/44/48 のみ、`failed to switch` は 0、再告知カウンターから 149 が消えた。
- 一覧表示への効果は iPhone 実機試験で確認する。

### 一覧表示の安定化 (12:54–13:03)

- ch149 修正だけの試験 (12:54): 12:52 に TCP 接続失敗 3 回（RST/EAGAIN）→ 12:54:54 Discover → 1分未満で一覧から消えた。
- 20秒の電波採取で election TLV を解析: **周囲の全端末（iPhone・自機含む）が同じトップマスター `92:yy:yy:yy:yy:yy` に揃っていた**。
  filin ログの「master」の入れ替わりは sync 親（直接の同期先）の入れ替わりで、クラスターは1つ。
- 本当の問題: filin は sync 親の chanseq をそのままコピーしていた。親が数秒ごとに変わるたびに自機の予定表が変わり、
  大半が ch48。共有シートを開いた iPhone は `[44,44,44,0,…,6,44,44,…]` で、重なりは16スロット中2〜3。
- `patches/0010`（opendrop-rs `airbridge/tlv-only`）: `FILIN_OWN_SEQUENCE=1` で、マスターからは AW のタイミングだけを取り、
  自機の予定表は 44 固定（スロット8のみ ch6、Apple 端末と同じ）を告知・追従する。既定はオフ。テスト 233 件 pass。
  drop-in `systemd/airbridge-awdl.service.d/20-own-sequence.conf` で有効化。
- 結果 (12:59 起動): **起動11秒で Discover、すぐ一覧に表示**。一度消えて再表示後は **表示され続けた**（13:01–13:03、ユーザー報告）。
  13:03 写真送信: Ask→Upload 完了まで **約2.2秒**（2.85 MB、約1.3 MB/s。12:01 は 3.7 MB で約7秒）。iPhone「送信成功」。
- 気づき: 同じファイル名（`IMG_1582.jpg`）を再送すると incoming の既存ファイルを**上書き**する。Gate G で対処する。

### 再起動テスト（13:04 起動）

- `sudo reboot` 後、radio → awdl → receiver の順に起動し、3つとも正常（順序の循環は解消済み）。
- filin の環境に `FILIN_OWN_SEQUENCE=1` が入っており、起動直後に予定表 `[44×8, 6, 44×7]` を使用（drop-in `20-own-sequence.conf` が有効）。
- 起動から約11秒で最初の Discover（13:04:55）。その後も 13:07–13:12 に Discover が続いた。
- 13:14:20 に写真送信: Ask → Upload 完了まで **約6.2秒**（`IMG_1576.jpg`、2.85 MB）。13:03 の 2.2 秒より遅いが成功。

## Gate F: USB gadget + Web UI (13:20–)

- 前提: Pi 4 の USB-C（dwc2）は既定でホストモード、`usb0` なし、`airbridge-usb/web` は disabled。
  元の `usb-network.sh` はアドレスを付けるだけで DHCP がなく、PC は 10.55.0.1 に届かなかった。
- 接続先は Windows、電源は PC の USB-C から（ユーザー回答）。
- `scripts/usb-gadget.sh`: configfs で RNDIS gadget（MS OS 記述子 `RNDIS`/`5162001`。Windows が標準ドライバを自動で当てる）。
  MAC はボードのシリアルから決める（Pi 側 `02:41:…`、PC 側 `02:42:…`）ので、Windows 側でアダプタが毎回増えない。
- `usb-network.sh`: `usb0` に 10.55.0.1/24 → dnsmasq で DHCP `10.55.0.10–50`。**ゲートウェイと DNS は配らない**ので、PC のインターネット接続に影響しない。
  NetworkManager には `conf.d/90-airbridge-usb.conf` で `usb0` を管理させない（rpi-usb-gadget の ICS は使わない）。
  → **10/9 撤去**（下記「Wi-Fi 設定の消失」）。
- `server.py`: `IP_FREEBIND` で `usb0` のアドレスが付く前でも 10.55.0.1 で待ち受けられる。一覧は5秒ごとに自動更新。
- config.txt に `[all] dtoverlay=dwc2,dr_mode=peripheral` を追記（バックアップ `config.txt.pre-gadget`）。
- 再起動なしでの確認（`dtoverlay dwc2 dr_mode=peripheral` を実行時に適用）: gadget が `fe980000.usb` に結び付き、`usb0` に 10.55.0.1、
  dnsmasq 起動、`curl http://10.55.0.1:8080/` で4ファイル表示、`IMG_1576.jpg` を 200 で 2,849,828 B 取得。`throttled=0x0`。
- 未確認: Windows PC 側の認識、DHCP、ブラウザでの取得、PC 給電での電圧。

### Wi-Fi 設定の消失と 10/9 朝の状態

- 10/9 07:03 起動時、wlan0 に接続設定がなく Wi-Fi につながらなかった（ssh 不可）。起動約2分後にユーザーが手動で `<SSID>` を作り直した
  （`/etc/NetworkManager/system-connections/<SSID>.nmconnection`、keyfile、自動接続あり）。
- 原因: このイメージは Imager の cloud-init で、Wi-Fi／有線の設定は netplan（`/etc/netplan/90-NM-*.yaml`）にあった。
  Gate F 導入時（10/8 13:21）の `nmcli general reload conf` の直後に、その2ファイルが **0 バイト**になっていた。
  動作中の接続はメモリに残ったので当日は気づかず（12:16・13:04 の再起動テストは reload より前）。
- 対処: `conf.d/90-airbridge-usb.conf` を撤去。NetworkManager は gadget を最初から管理しない
  （`/usr/lib/udev/rules.d/85-nm-unmanaged.rules` の `DEVTYPE=="gadget"`、usb0 に `NM_UNMANAGED=1` を確認）ので不要だった。
  `install.sh` は NM の設定に触れず、旧ファイルを消すだけ（reload しない）。空の netplan ファイル2つも削除。
- 10/9 朝、Windows につないでいないのに USB-C 側のホストが gadget を列挙していた（起動から23秒後、address 8、`configured`）。
  ただし `usb0` の受信は0パケット、DHCP の要求もなし。電源の相手は未確認。
- 電圧: 起動4秒後に `Undervoltage detected!`、08:32 時点で `throttled=0x50005`（電圧不足と速度低下が継続中）。
- 未確認: 再起動後に Wi-Fi が自動でつながること。

## 名称変更: AirBridge → LilBitDrop (10/9)

- 同名の製品やプロジェクトが多い（AB180 の広告計測サービス Airbridge、App Store の iPhone↔Mac 転送アプリ、GitHub 上の AirPlay 関連など）ので、公開名を **LilBitDrop** に変更。
- 変えたもの: README・ドキュメントの表記、共有シートに出る受信機名（`--name LilBitDrop`）、mDNS インスタンス（`LUFTLIFT_INSTANCE=lilbitdrop`）、
  Web UI の見出し、USB gadget の製造元名・製品名、systemd の Description。
- 変えていないもの: ユニット名 `airbridge-*`、`/opt/airbridge`、`/etc/airbridge.conf`、`/var/lib/airbridge`、config.txt の目印 `# AirBridge USB gadget`、
  `patches/` 内のコメント。この節より前の記録は当時の名前のまま。

## 再起動テスト（10/9 11:16 起動）

- Wi-Fi: 起動14秒で `<SSID>` に自動接続（keyfile の設定で。手操作なし）。**Wi-Fi 設定消失の対処は有効。**
- USB: gadget の製造元名・製品名は `LilBitDrop` / `LilBitDrop USB Network`。Web UI の title も LilBitDrop。`throttled=0x0`、電圧不足は0回（今回の給電では問題なし）。
- **receiver が起動しなかった**:
  1. radio-setup の1回目の再読込（9.2s）後、インターフェースが戻った直後の確認でまだ `no IR` → 失敗（17.1s）。
  2. awdl の `filin-guard` も `no IR` で失敗 → receiver は `Requires=` のため `Job ... failed with result 'dependency'` で終了し、以後誰も起動しない。
  3. awdl は `Restart=always` で再試行 → `Wants=` で radio-setup が再実行され2回目の再読込（19.8s）→ 26.7s に送信可能、awdl は起動。
- 危険の発見: radio-setup は awdl が再起動するたびに実行されるので、「1回だけ」は1プロセス内の話にすぎず、
  `no IR` が直らなければ数秒ごとに再読込を繰り返す（10/8 に USB 列挙不能を起こした状況）。
- 修正:
  - radio-setup: 再読込回数を `/run/airbridge/radio-reloads` で起動ごとに数え、**最大2回**（今回、10秒間隔の2回は問題なく、2回目で直った）。
    再読込後はインターフェースが戻ってからも最大20秒、`no IR` が消えるのを待つ。上限に達したら再読込せず「抜き差しして」と出して失敗。
  - receiver: `Requires=` → `Wants=` + `PartOf=airbridge-awdl.service` + `StartLimitIntervalSec=0`。awdl の初回失敗で receiver が見捨てられない。
  - 実機に反映し、receiver を手動起動。AWDL の告知は `instance: "lilbitdrop"`。
- 未確認: 修正後の再起動、iPhone の共有シートに「LilBitDrop」と出るか。
- 11:29 iPhone の共有シートに **「LilBitDrop」と表示**（ユーザー確認）。PNG 1枚を送信: Ask 11:29:14.8 → Upload 完了 11:29:20.2（**約5.4秒**、4,000,944 B、
  PNG 1254×1254）。iPhone「送信済み」。AppleDouble の `._*.PNG`（1,751 B）も一緒に保存される（当初「保存されない」と書いたのは `ls` が隠しファイルを表示しなかったための誤り）。Web UI の一覧にも出る。

## 再起動テスト（10/9 13:35 頃起動、receiver 修正後）

- 5サービスとも起動、失敗なし。radio-setup は1回の再読込（16.2s）で送信可能に（24.4s、回数記録 `1`）→ awdl 24.6s → **receiver 24.7s に自動起動**（再起動回数 0）。
  35s に AWDL 告知 `instance: "lilbitdrop"`。Wi-Fi は自動接続、USB の名前は LilBitDrop。
- 電源: 今回は起動中に電圧不足が4回、`throttled=0x50005`（11:16 起動時は0回）。給電の条件は要確認。
- 13:38 同じ PNG を再送: Ask 13:38:39.6 → Upload 完了 13:38:47.2（約7.6秒）。iPhone 側は成功。電圧不足が出ている状態（起動以降8回、`0x50005`）でも転送できた。
  同名のため 11:29 のファイルを**上書き**（Gate G の課題）。

## Gate G: 同名ファイルの上書き・`._` の表示、および保存先の脆弱性 (13:45–)

- **脆弱性**: luftlift は cpio のエントリ名をそのまま `output_dir.join(name)` していた。`../` や絶対パスの名前で受信フォルダの外に書ける。
  luftlift は root で動き、「すべての人」モードでは自動受け入れなので、近くの誰でも Pi の任意のファイルを root で書き換えられる状態だった。
- `patches/0011`（opendrop-rs `ccf03c9`）: 保存はエントリ名の最後の要素（`/` と `\` で区切る）だけを使い、空・`.`・`..` は捨てる。
  `create_new` で作り、名前が使われていれば `name-1.ext`、`name-2.ext`…（同名の再送で上書きしない）。`._a.PNG` は `._a-1.PNG`。
  単体テスト3件を追加、luftlift のテスト全件 pass。実機に入れ替え（旧版 `/opt/airbridge/bin/luftlift.pre-0011`）。
- Web UI: 先頭が `.` のファイル（AppleDouble `._*`）を一覧に出さない。
- 14:14 同じ PNG を再送: Ask→Upload 完了 約4.8秒。**`…-1.PNG` として保存され、13:38 の元ファイルはそのまま**（内容は同一、`cmp` 一致）。`._…-1.PNG` も同様。Web UI は2枚とも表示し、`._*` は出ない。

## Gate F 続き: Mac 対応（RNDIS + ECM） (14:30–)

- 10/9 07:03 起動時に USB の先にいたのは **Mac**（ユーザー確認）。gadget は列挙された（`configured`）が受信0パケット。**macOS には RNDIS のドライバがない**ため。
- 13:16 起動以降は Windows（PC の USB-A → Pi の USB-C、Pi の給電も同じケーブル）につないでいるが UDC は `not attached`（列挙されていない）。
  充電専用ケーブル、または電力不足（USB-A は 500–900 mA、起動以降電圧不足が継続）を疑う。未解決。
- `usb-gadget.sh`: 構成を2つにした。c.1 = RNDIS + MS OS 記述子（Windows）、c.2 = CDC-ECM（macOS・Linux）。ホストがドライバのある方を選ぶ。
  それぞれの netdev（`lbdrndis0`、`lbdecm0`）をブリッジ `usb0` に入れ、10.55.0.1・dnsmasq・Web UI は従来どおり `usb0` で動く。
  ブリッジは STP なし・forward_delay 0（既定 15 秒だと DHCP が遅れる）。MAC はボードのシリアルから（RNDIS 02:41/02:42、ECM 02:44/02:43）。
  gadget の `ifname` は bind 前に `%d` を含むパターンしか受け付けない（固定名は EINVAL）。
- NetworkManager: ポートは gadget なので最初から管理外。ブリッジは gadget ではないので、udev ルール `90-lilbitdrop-usb.rules` で `NM_UNMANAGED=1`
  （NM の設定は触らない、reload もしない）。3つとも `unmanaged` を確認。
- 実機で gadget を作り直し: c.1/c.2 とも作成、ブリッジに2ポート、`usb0` に 10.55.0.1、dnsmasq 起動、Web UI 200。
- 未確認: Mac での ECM の選択・DHCP・ブラウザでの取得、再起動後の自動構成、Windows。

### Mac での確認（10/9 19:18 頃起動、iMac 24" M1 に接続・給電）

- 再起動後、ブリッジとポートは自動で構成。12.8s に列挙、**Mac は c.2（ECM）を選択**（`lbdecm0` UP、`lbdrndis0` は NO-CARRIER）。
- DHCP: `iMac-24-M1` に 10.55.0.42（host MAC 02:43:…、ECM 側）。Mac のネットワーク設定にも表示（ユーザー確認）。
- Web UI: Mac から `GET /` 200、`GET /files/…-1.PNG` 200（ダウンロード成功、ユーザー確認）。`lbdecm0` rx 1955 / tx 3329 パケット。
- 5サービスとも active、`throttled=0x0`、電圧不足0回（この Mac の USB 給電では問題なし）。
- **Gate F は macOS で達成。** Windows は未確認（USB-A 給電で未列挙、ケーブル/電力を要調査）。

### 10/10 05:10 起動（Windows に接続）

- 訂正: 直前の記録（`bbbfc3d`）は「Windows のブラウザで取得成功」と誤記。ユーザーが成功と報告したのは **iPhone → Pi の AirDrop 転送**で、Windows のブラウザでの取得は未確認。
- Pi を Windows PC（USB-A）につないで起動。UDC は `not attached`（gadget は 18s に bind されたが列挙されず）、DHCP リースなし。**USB ネットワークは今回も不成立。**
- その状態で AirDrop 受信は成功: 05:16:28.8 Ask → 05:16:33.9 保存（約5.1秒）、`FullSizeRender.jpg` 3,331,757 B、JPEG 5341×3170、iPhone Air / 27.2。
- 電源: 起動10.8s から電圧不足、確認時点（起動8分）で21回、`throttled=0x50000`（過去に発生、確認時点では発生中でない）。

### Windows での確認（10/10 05:49 頃起動、別の PC・別のケーブル）

- 別の Windows PC（ホスト名 `N100Note`）と別のケーブルで接続。起動12.8s に列挙（high-speed、address 7）、**Windows は c.1（RNDIS）を選択**（`lbdrndis0` up、`lbdecm0` down）。
- DHCP: `N100Note` に 10.55.0.44（vendor class `MSFT 5.0`、host MAC 02:42:…＝RNDIS 側）。
- Web UI: 10.55.0.44 から `GET /` 200 が5秒ごと（自動更新）。`lbdrndis0` rx 487 / tx 422。ファイル取得（`/files/…`）のログはこの時点でなし。
- 電源: 電圧不足4回、`throttled=0x50000`（確認時点で発生中ではない）。
- 前回失敗（別 PC・別ケーブル）との差の切り分け（ケーブルか PC か）は未実施。
