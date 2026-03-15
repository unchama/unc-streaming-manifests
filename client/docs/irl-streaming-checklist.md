# 外配信 (IRL Streaming) チェックリスト

外配信（IRL Streaming）を開始する前に確認すべき項目をまとめたチェックリスト。

## 出発前の準備

- [ ] バッテリー充電確認（PC、GoPro、モバイルルーター）
- [ ] GoPro USB ケーブル接続確認
- [ ] モバイル回線のデータ残量確認
- [ ] サーバー側サービスの稼働確認
- [ ] リレー設定のストリームキーが有効か確認（期限切れ注意）
- [ ] 配信プラットフォームのダッシュボードで配信枠が設定済みか確認（YouTube の場合）

```bash
ssh unc-streaming-01.seichi.internal -l cloudinit
systemctl status srt-live-server srtla-rec
```

## 現場での起動手順

1. PC 起動、WiFi / モバイル回線接続
2. ネットワーク確認: `ip -4 addr show` で各 NIC に IP が振られていること
3. GoPro 接続: USB 接続 → `ip link show` で `enx*` が見えること
4. exclude_devs 確認: GoPro NIC が `/etc/srtla-send/exclude_devs` に登録されていること
5. srtla-send 起動: `sudo systemctl start srtla-send`
6. ips_file 確認: `cat /etc/srtla-send/srtla_ips` で IP が記載されていること
7. キャプチャ起動: `sudo systemctl start srt-capture-gopro`（GoPro 使用時）
8. 配信確認: Stats API で bitrate > 0 を確認

## 配信中の監視

Stats API でストリームの状態を確認する。詳細は [Stats API](stats-api.md) を参照。

```bash
curl -H "Authorization: Bearer <API_KEY>" http://unc-streaming-01.seichi.internal:8181/stats
```

| 指標 | 目安 |
|---|---|
| RTT | < 50ms が良好、> 100ms で遅延注意 |
| pktRcvLoss | 継続的に増加する場合は回線品質に問題 |

### パケットロス増加時の対応

1. `pktRcvLoss` が急増している場合、特定回線の品質劣化の可能性
2. 可能であれば問題のある回線を切断（テザリング OFF 等）
3. `sudo systemctl reload srtla-send`（SIGHUP で ips_file 再読み込み）
4. 残りの回線で配信を継続

### サーバー側リソース確認

```bash
ssh unc-streaming-01.seichi.internal -l cloudinit
top -bn1 | head -5
systemctl status srt-live-server srtla-rec srt-relay@youtube
```

debug リレー（x264 エンコード付き）使用時は CPU 使用率に注意。

## 緊急対応（配信が途切れた場合）

1. `ip -4 addr show` でネットワーク接続を確認
2. `systemctl status srtla-send` でサービス状態を確認
   - `failed (start-limit-hit)` の場合:
     ```bash
     sudo systemctl reset-failed srtla-send
     sudo systemctl start srtla-send
     ```
   - `active` だが映像が出ない場合: Stats API で RTT / pktRcvLoss を確認
3. 回線が全滅している場合: WiFi 再接続 or テザリング再接続後に `sudo systemctl restart srtla-send`
4. キャプチャが停止している場合: `systemctl status srt-capture-gopro` で確認し、必要なら `sudo systemctl restart srt-capture-gopro`

## 配信終了手順

1. `sudo systemctl stop srt-capture-gopro`（または `srt-capture`）
2. `sudo systemctl stop srtla-send`
3. サーバー側リレーは起動したままで OK（入力がなければ待機状態）

## 回線構成の注意

- 単一回線運用は冗長性がないため、回線切断 = 配信停止
- テザリングは WiFi テザリングではなく **USB テザリング** を使用すること（WiFi テザリングは周囲の WiFi 環境に品質が左右される）
- 複数のスマートフォンを USB テザリングで接続し、SRTLA ボンディングで束ねるのが最も安定する構成
- 回線追加時の設定は [ネットワーク設定](network-setup.md) を参照
