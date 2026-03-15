# SRT バッファチューニング

配信PC（srtla_send）と配信サーバー（srt_server）間の SRT 通信品質を左右するバッファ設定について解説する。

## バッファの役割

SRT はUDPベースのプロトコルであり、以下の機能を受信バッファで実現している:

```
送信側 (配信PC)                                     受信側 (配信サーバー)
ffmpeg → SRT → srtla_send ===[モバイル回線]=== srtla_rec → [受信バッファ] → srt_server → リレー
                                                            ├─ パケット並べ替え
                                                            ├─ 再送待ち
                                                            └─ ジッター吸収
```

- **パケット並べ替え**: UDP はパケットの到着順が保証されないため、バッファ内で正しい順序に並べ直す
- **再送待ち**: パケットロス検知時、再送要求 → 再送パケット到着まで待つスペースを確保する
- **ジッター吸収**: ネットワーク遅延の揺らぎを吸収し、安定したデータ供給を維持する

バッファが小さすぎるとパケットロスやドロップが発生し、映像が乱れる。大きすぎると配信遅延が増加し、メモリ消費も増える。

## 主要パラメータ

SRT URL のクエリパラメータとして指定する。

| パラメータ | 単位 | デフォルト | 説明 |
|-----------|------|----------|------|
| `latency` | μs | 120000 (120ms) | 送受信バッファの保持時間。再送を待てる最大時間を決定する。値が大きいほどロス耐性が上がるが、配信遅延が増える |
| `rcvlatency` | μs | `latency` と同値 | 受信側のみのバッファ時間。`latency` より優先される |
| `peerlatency` | μs | 0 | 相手側に要求するバッファ時間 |
| `rcvbuf` | bytes | ~8MB | 受信バッファサイズ。通常は `latency` に連動して自動調整されるため明示指定は不要 |
| `sndbuf` | bytes | ~8MB | 送信バッファサイズ。同上 |
| `fc` | packets | 25600 | フロー制御ウィンドウ。同時にネットワーク上に存在できる未確認パケットの最大数 |
| `tlpktdrop` | 0/1 | 1 | 遅延超過したパケットを破棄する。ライブ配信では 1 (有効) にすべき |
| `maxbw` | bytes/s | 0 (無制限) | 最大送信帯域。0 で自動推定 |

> **単位に注意**: `latency` はマイクロ秒 (μs) 指定。1000ms = `latency=1000000`。

## 現在の設定

### 配信PC → 配信サーバー間（メイン経路）

```
ffmpeg → SRT (latency=1000ms) → srtla_send ===[SRTLA]=== srtla_rec → srt_server
```

| 設定箇所 | ファイル | パラメータ | 値 |
|---------|---------|-----------|-----|
| キャプチャ出力 (Cam Link) | `srt-capture.env` | `latency` | 1000000 (1000ms) |
| キャプチャ出力 (GoPro) | `srt-capture-gopro.env` | `latency` | 1000000 (1000ms) |
| srt_server 受信 | `sls.conf` | `latency_min` | 200 (ms) |
| srt_server 受信 | `sls.conf` | `latency_max` | 5000 (ms) |

SRT の latency は送受信で **ネゴシエーション** される。実際に適用される値は、送信側の `latency` とサーバー側の `latency_min` の大きい方になる。現在の構成では `max(1000, 200) = 1000ms` が適用される。

### サーバー内部（リレー経路）

```
srt_server :4000 → ffmpeg (srt-relay@) → RTMP push
                 → ffmpeg (srt-relay-debug@) → SRT :4003
```

| 設定箇所 | ファイル | パラメータ | 値 |
|---------|---------|-----------|-----|
| 本番リレー入力 | `relay-*.env` | (未指定) | デフォルト 120ms |
| debug リレー入力 | `relay-debug-*.env` | `rcvlatency` | 300 (μs表記だが実質ms) |
| debug リレー出力 | `relay-debug-*.env` | `latency` | 1000 (μs表記だが実質ms) |

サーバー内部は localhost 通信のためネットワーク遅延・ジッターは発生しない。デフォルト値で十分。

## 回線品質別の推奨 latency

配信PC側の `SRT_OUTPUT` に設定する `latency` の推奨値。

| 環境 | RTT目安 | 推奨 latency | 設定値 (μs) |
|------|---------|-------------|------------|
| 有線 LAN / localhost | < 1ms | 200ms | 200000 |
| 安定した WiFi (屋内) | 1-10ms | 500ms | 500000 |
| モバイル回線 (安定時) | 10-50ms | 1000ms | 1000000 |
| モバイル回線 (混雑・移動中) | 50-200ms | 2000ms | 2000000 |
| 極端に不安定な回線 | > 200ms | 3000-5000ms | 3000000-5000000 |

**IRL 配信（外配信）ではモバイル回線のベストエフォート性を考慮し、安定重視の 1000ms 以上を推奨する。** モバイル網は基地局の混雑、ハンドオーバー、電波強度の変動で瞬間的に RTT が跳ねるため、バッファに余裕を持たせた方が配信の乱れが少ない。

## チューニング手順

### 1. 現在の品質を確認

Stats API でリアルタイムの品質指標を取得する:

```bash
curl -H "Authorization: Bearer <API_KEY>" http://unc-streaming-01.seichi.internal:8181/stats
```

注目すべき指標:

| 指標 | 意味 | 目安 |
|------|------|------|
| `rtt` | ラウンドトリップタイム (ms) | latency はこの2-5倍以上が安全 |
| `pktRcvLoss` | パケットロス数 | 増加が継続するなら latency 不足の可能性 |
| `pktRcvDrop` | パケットドロップ数 | バッファ超過で破棄されたパケット。latency を増やすと改善する場合がある |
| `msRcvBuf` | 受信バッファ使用量 (ms) | latency に近い値が続くならバッファが逼迫している |

### 2. latency を変更

クライアント側の env ファイルを編集:

```bash
# 配信PCで実行
sudo nano /etc/srtla-send/srt-capture-gopro.env
# SRT_OUTPUT の latency=XXXXXX を変更

# キャプチャサービスを再起動
sudo systemctl restart srt-capture-gopro
```

### 3. 変更後の確認

Stats API で `pktRcvLoss` と `pktRcvDrop` のカウンタをリセット直後から監視する。ロス/ドロップの増加速度が緩和されていれば改善している。

## バッファ枯渇のトラブルシューティング

受信バッファが枯渇すると以下のログが出る:

```
No room to store incoming packet ... Space avail 0/8192 pkts.
```

### 原因と対処

| 原因 | 対処 |
|------|------|
| 出力側の処理が追いつかない（ffmpeg のエンコード負荷等） | 出力側の latency を適切な値に下げる。CPU 負荷を確認し、エンコード設定を見直す |
| ネットワークのジッターが latency を超えている | latency を増やす |
| `rcvbuf` / `fc` が不足（通常は発生しない） | SRT URL に `rcvbuf=16777216` 等を追加。ただし根本原因は上記2つのいずれかであることが多い |

> **注意**: バッファサイズ (`rcvbuf`) を増やしても、アプリケーション側が読み取らなければバッファは溜まる一方になる。`rcvbuf` の増量は対症療法であり、根本原因（出力停滞やネットワーク品質）の解消が先。

## sls.conf の latency_min / latency_max

srt_server (`sls.conf`) 側の `latency_min` / `latency_max` はサーバーが受け入れるクライアントの latency の範囲を制限する。

```nginx
latency_min 200;    # 200ms 未満は拒否
latency_max 5000;   # 5000ms を超える値は拒否
```

クライアントが `latency=1000ms` で接続すると、サーバー側も 1000ms のバッファを確保する。`latency_max=5000` なので、現在の設定では最大 5秒まで増やせる。
