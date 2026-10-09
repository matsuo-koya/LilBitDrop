# 引き継ぎ: Mac 側の Claude Code で内蔵 Wi-Fi（Nexmon）を試す

このメモは、**Mac 上で動かす Claude Code** 向け。Pi 上の Claude Code は API 通信に wlan0 を使うので、
wlan0 を Nexmon に切り替えると止まる。以後の操作はすべて Mac から USB 経由の SSH で行う。

## 0. 準備（ユーザーが Mac で一度だけ）

```bash
ssh-copy-id koya@10.55.0.1          # パスワードなしで入れるように
ssh koya@10.55.0.1 'sudo -n true && echo ok'   # sudo もパスワードなしで通ること
git clone https://github.com/matsuo-koya/LilBitDrop.git && cd LilBitDrop
git switch research/nexmon-bcm43455
claude                               # この README と HANDOFF.md を読ませてから始める
```

Pi 上のコマンドはすべて `ssh koya@10.55.0.1 '…'` で実行する。リポジトリは Pi の `~/airbridge` にもある（同じブランチ）。

## 守ること

- **`nmcli general reload conf` は実行しない**（2026-10-08、netplan の Wi-Fi 設定が空になった）。NM の設定ファイルも触らない。
- carl9170（WL300NU-AG）のドライバ再読込は**1回の起動につき2回まで**（短時間に3回で USB 列挙不能、物理的な抜き差しが必要になった）。
- USB 接続（usb0 = 10.55.0.1）は管理経路。`airbridge-usb` を止めない。
- 作業前と節目で `docs/DIAGNOSTICS.md` 形式の記録を `research/nexmon/README.md` に追記し、Mac 側でコミットして push。
- 戻すときは `sudo ~/airbridge/research/nexmon/rollback.sh`。戻した後 wlan0 は保存済みの Wi-Fi に自動で再接続する。

## 現状（2026-10-09 21:04 時点）

- 準備済み（未有効化）: `/opt/airbridge/research/nexmon/`
  - `cyfmac43455-sdio-nexmon.bin`（Kali firmware-nexmon 0.2 の 7.45.206 Nexmon 版）
  - `brcmfmac-nexmon-6.18.50+rpt-rpi-v8.ko`（Kali brcmfmac-nexmon-dkms 6.12.2 + `brcmfmac-nexmon-dkms-6.12.2-to-6.18.diff`）
  - `orig/state.txt`（元の FW: 7.45.265、alternatives は standard）、`SHA256SUMS`
- CLM blob は Kali 版と同一なので差し替えない。
- 本番サービス（`airbridge-*`、外付け wlan1 で filin）は動作中。

## 手順

1. **有効化**: `ssh koya@10.55.0.1 'sudo ~/airbridge/research/nexmon/enable.sh'`
   - 確認: `modinfo -n brcmfmac` が `…/updates/brcmfmac.ko`、dmesg の Firmware が `7.45.206`、wlan0 が存在。
   - 失敗・カーネル警告（`dmesg | grep -iE 'brcmf|oops|warn'`）が出たら rollback して記録。
2. **監視 IF の作成**: `sudo iw phy <phy of wlan0> interface add mon0 type monitor && sudo ip link set mon0 up`
   - MAC が `00:00:00:00:00:00` にならないか（OWL issue #63 の症状）。`iw dev mon0 set channel 44` が通るか。
   - wlan0 は `sudo nmcli dev set wlan0 managed no`（実行時の設定のみ、reload ではない）で NM から外してよい。
3. **送信が電波に出るかの確認**（外付けを測定器に）:
   - `sudo systemctl stop airbridge-receiver airbridge-awdl`（本番を止める。戻すときは start）
   - wlan1（carl9170）は filin が監視モード・ch44 にしたまま残る。`sudo iw dev wlan1 set channel 44` で固定し、
     `sudo tcpdump -i wlan1 -e -c 200 ether host <mon0 の MAC>` で受信。
   - mon0 側で filin を起動: `sudo /opt/airbridge/bin/filin -i mon0 -c 44 -h awdl0 -N --no-force-master`
     （`-N` = 監視モード設定を自分でしない。Nexmon の mon0 用）
   - 見るもの: mon0 の MAC から AWDL アクションフレームが ch44 で出ているか。awdl0 上で mDNS（データフレーム）も出ているか。
4. **同期精度**: filin の `http://127.0.0.1:9930/status`（`synced`, `aw_alignment_pct`, `master_changes`）を 3 分。
   比較基準: carl9170 では synced=true、alignment 90% 前後（`docs/DIAGNOSTICS.md` Phase 1）。
5. **iPhone 試験**: `airbridge-receiver` の代わりに luftlift を手で起動（`--name LilBitDrop-int`）し、共有シートに出るか・写真が届くか。
6. **後片付け**: `rollback.sh` → 本番サービスを start → `airbridge-awdl` が wlan1 で動き、受信できることを確認。

## 判定の目安

| 段階 | 合格 | 不合格なら |
|---|---|---|
| 1 | Nexmon FW が読み込まれ、警告なし | rollback。ドライバ移植の問題として記録 |
| 2 | mon0 作成、MAC 正常、ch44/ch6 に設定可 | MAC 0 → filin 側で MAC を指定できるか検討 |
| 3 | ch44 でアクション + データフレームが測定器に見える | データが出ない → rtw88 と同じ結論（内蔵は不可） |
| 4 | synced=true が続く | 同期できない → 時刻精度の問題として記録 |
| 5 | 一覧に表示・写真受信 | — |
