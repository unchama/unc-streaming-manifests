# unc-streaming-01 サーバーセットアップ

unc-streaming-01 のセットアップ・設定ファイル一式。

## アーキテクチャ

```
配信クライアント (x86 PC / BELABOX)
  |  複数モバイル回線 (SRTLA)
  v
srtla_rec :5000  (SRTLA受信・集約)
  |
  v
srt_server :4002 (listen_publisher_srtla)
  |
  +---> :4000 (listen_player / SRT視聴)
  +---> :4001 (listen_publisher / 直接SRT)
  +---> :8181 (HTTP Stats API)
  |
  v
ffmpeg (srt-relay@) -> RTMP push -> Twitch / YouTube 等
```

## サーバー情報

| 項目 | 値 |
|------|------|
| ホスト名 | unc-streaming-01 |
| IP | (VLAN100、別途確認) |
| Proxmoxホスト | unchama-sv-prox08 (VMID 202) |
| OS | Ubuntu 24.04 LTS |
| CPU / メモリ / ディスク | 8コア / 8GB / 50GB |

## 使用ソフトウェア

| ソフトウェア | バージョン | リポジトリ |
|---|---|---|
| libsrt (BELABOX fork) | v1.5.4 | [irlserver/srt](https://github.com/irlserver/srt) (belabox branch) |
| srtla | v1.0.0 | [irlserver/srtla](https://github.com/irlserver/srtla) |
| irl-srt-server | v3.1.0 | [irlserver/irl-srt-server](https://github.com/irlserver/irl-srt-server) |
| ffmpeg | 6.1.1 | apt (ubuntu 24.04) |

## ファイル構成

```
server/
├── README.md                     # このファイル
├── BUILD_PROCEDURES.md           # 詳細ビルド手順書
├── build-all.sh                  # 自動ビルドスクリプト (srt + srtla + irl-srt-server)
├── setup-services.sh             # systemdサービスインストールスクリプト
├── sls.conf.template             # srt_server設定ファイル
├── relay.env.template            # ffmpegリレー用環境変数テンプレート
├── relay-debug.env.template      # デバッグリレー用環境変数テンプレート
├── stats-collector.env.template  # Stats Collector用環境変数テンプレート
├── scripts/
│   ├── srt-stats-collector.sh    # SRT統計オーバーレイテキスト生成スクリプト
│   ├── srtla-ip-mapper.sh        # SRTLAリンクのポート→送信元IP解決スクリプト
│   ├── srt-relay-overlay.sh      # 本番リレーのデバッグオーバーレイ ON/OFF 切り替え
│   └── srt-relay-watchdog.sh     # リレー出力停滞検知・自動再起動スクリプト
└── systemd/
    ├── srtla-rec.service         # srtla_rec systemdユニット
    ├── srt-live-server.service   # srt_server systemdユニット
    ├── srt-relay@.service        # ffmpegリレー テンプレートユニット
    ├── srt-relay-watchdog.service  # リレー watchdog oneshot ユニット
    ├── srt-relay-watchdog.timer    # リレー watchdog タイマー (60秒間隔)
    ├── srtla-ip-mapper.service   # IP Mapper oneshot ユニット
    ├── srtla-ip-mapper.timer     # IP Mapper タイマー (10秒間隔)
    ├── srt-stats-collector.service   # Stats Collector systemdユニット
    └── srt-relay-debug@.service  # デバッグリレー テンプレートユニット
```

## セットアップ手順

### 1. ビルド

```bash
sudo ./build-all.sh
```

詳細なビルド手順は [BUILD_PROCEDURES.md](BUILD_PROCEDURES.md) を参照。

### 2. サービスインストール

```bash
sudo ./setup-services.sh
```

### 3. サービス起動

```bash
# srt-live-server を先に起動 (srtla-rec は srt-live-server:4002 に接続するため)
sudo systemctl start srt-live-server
sudo systemctl start srtla-rec
```

> **起動順序**: `srtla-rec` は `Requires=srt-live-server.service` + `After=srt-live-server.service` を設定しているため、`systemctl start srtla-rec` だけでも srt-live-server が自動的に先に起動する。

### 4. リレー設定 (配信プラットフォームへの転送)

```bash
# ストリームキー設定
sudo nano /etc/srt-live-server/relay-twitch.env

# 有効化・起動
sudo systemctl enable --now srt-relay@twitch
```

## リレー Watchdog (自動復旧)

`srt-relay@*` の ffmpeg は `Restart=always` でプロセス死亡時は自動復帰するが、ffmpeg プロセスが生きたまま RTMP 出力が停滞するケース（YouTube 側が配信停止と判定した場合など）には対応できない。

`srt-relay-watchdog` は 60秒ごとに各リレーの出力バイト数をサンプリングし、停滞を検知したらサービスを再起動する。

### 判定ロジック

1. Stats API で publisher の有無を確認（publisher がなければスキップ）
2. 各 `srt-relay@*` の ffmpeg PID の `/proc/<pid>/io` から `write_bytes` を5秒間隔で2回取得
3. 増加していなければ出力停滞と判断し `systemctl restart` を実行

### セットアップ

```bash
sudo install -m 0755 scripts/srt-relay-watchdog.sh /usr/local/bin/srt-relay-watchdog.sh
sudo cp systemd/srt-relay-watchdog.service systemd/srt-relay-watchdog.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now srt-relay-watchdog.timer
```

### ログ確認

```bash
journalctl -u srt-relay-watchdog -f
```

## デバッグオーバーレイ (SRT/SRTLA 統計表示)

配信映像にSRT通信統計とSRTLAリンク別ステータスをオーバーレイ表示するデバッグ用リレー。
本番配信 (`srt-relay@`) には一切影響しない独立したストリーム。

### 仕組み

```
srt_server :8181 (Stats API)  +  srtla_rec ログ (journalctl)
  |                                  |
  |  1秒間隔ポーリング                |  最新のリンク情報をパース
  v                                  v
srt-stats-collector ──────> /tmp/srt-overlay.txt
  ^                             |  drawtext reload=1
  |                             v
  | /tmp/srtla-ip-map      srt-relay-debug@ or srt-relay-overlay.sh on
  | (ポート→IP対応表)        (ffmpeg: SRT入力 → x264再エンコード+オーバーレイ → SRT/RTMP出力)
  |                             |
srtla-ip-mapper (10秒間隔)      v
  (tcpdump + 逆引きDNS)    :4003 (SRT視聴) or 本番リレー
```

### 本番リレーのオーバーレイ ON/OFF

`srt-relay-overlay.sh` で本番リレー (例: `srt-relay@youtube`) にデバッグオーバーレイの ON/OFF を切り替えできる。ON にすると映像が x264 再エンコードになるため CPU 負荷が増加する。

```bash
# オーバーレイ ON (x264 再エンコード + drawtext)
sudo srt-relay-overlay.sh on youtube

# オーバーレイ OFF (video passthrough に戻す)
sudo srt-relay-overlay.sh off youtube

# 現在の状態確認
sudo srt-relay-overlay.sh status youtube
```

### 表示内容

```
Bitrate: 6267 kbps | RTT: 24.9 ms | Loss: 0 | Drop: 0 | BW: 248 Mbps
Link1 198.51.100.1 (example1.isp.ne.jp) W:100 Err:0
Link2 203.0.113.5 (example2.isp.ne.jp) W:85 Err:5
```

| 1行目 (SRT統計) | 説明 |
|---|---|
| Bitrate | 受信ビットレート (kbps) |
| RTT | ラウンドトリップタイム (ms) |
| Loss | 累積パケットロス数 |
| Drop | 累積パケットドロップ数 |
| BW | 推定帯域幅 (Mbps) |

| 2行目以降 (SRTLAリンク別、1行1リンク) | 説明 |
|---|---|
| Link N | リンク番号 |
| IP (hostname) | 送信元グローバルIP と逆引きホスト名 |
| W | パケット振り分け比率 (100=全力, 10=ほぼ未使用) |
| Err | エラーポイント (0=正常, 高い=回線不調) |

### セットアップ

`setup-services.sh` で自動インストールされる。手動の場合:

```bash
# スクリプトインストール
sudo install -m 0755 scripts/srt-stats-collector.sh /usr/local/bin/srt-stats-collector.sh
sudo install -m 0755 scripts/srtla-ip-mapper.sh /usr/local/bin/srtla-ip-mapper.sh
sudo install -m 0755 scripts/srt-relay-overlay.sh /usr/local/bin/srt-relay-overlay.sh

# tcpdump に CAP_NET_RAW を付与 (srtla-ip-mapper が非root ではなく root で動くが念のため)
sudo setcap cap_net_raw+ep /usr/bin/tcpdump

# systemdユニットインストール
sudo cp systemd/srt-stats-collector.service /etc/systemd/system/
sudo cp systemd/srtla-ip-mapper.service systemd/srtla-ip-mapper.timer /etc/systemd/system/
sudo cp systemd/srt-relay-debug@.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now srtla-ip-mapper.timer

# Stats API認証設定 (sls.conf に api_keys が設定されている場合)
echo 'SRT_API_KEY=your-api-key' | sudo tee /etc/srt-live-server/stats-collector.env
sudo chown root:srt /etc/srt-live-server/stats-collector.env
sudo chmod 0640 /etc/srt-live-server/stats-collector.env

# デバッグリレー設定 (デフォルトはSRT出力 port 4003)
sudo cp relay-debug.env.template /etc/srt-live-server/relay-debug-srt.env
sudo chown root:srt /etc/srt-live-server/relay-debug-srt.env
sudo chmod 0640 /etc/srt-live-server/relay-debug-srt.env
```

### 起動・停止

```bash
# 起動 (stats-collector は Wants= 依存で自動起動)
sudo systemctl start srt-relay-debug@srt

# 停止
sudo systemctl stop srt-relay-debug@srt

# stats-collector だけ起動 (オーバーレイファイルの生成確認用)
sudo systemctl start srt-stats-collector
cat /tmp/srt-overlay.txt
```

### 視聴

```
srt://unc-streaming-01.seichi.internal:4003
```

streamid やパラメータは不要。SRTプレイヤー (mpv, ffplay, VLC 等) で直接接続する。

### 設定変更

`/etc/srt-live-server/relay-debug-srt.env` を編集して `systemctl restart srt-relay-debug@srt` で反映。

| 変数 | デフォルト | 説明 |
|---|---|---|
| `SRT_INPUT` | `srt://127.0.0.1:4000?...` | SRT入力URL |
| `OUTPUT_URL` | `srt://0.0.0.0:4003?mode=listener&latency=300000` | 出力先URL (SRT/RTMP) |
| `OUTPUT_FORMAT` | `mpegts` | 出力フォーマット (`mpegts` or `flv`) |
| `X264_PRESET` | `ultrafast` | x264プリセット |
| `VIDEO_BITRATE` | `3000k` | 出力ビットレート |
| `OUTPUT_FPS` | `30` | 出力フレームレート |
| `OVERLAY_FONTSIZE` | `20` | フォントサイズ |
| `OVERLAY_FONTCOLOR` | `white` | フォント色 |
| `OVERLAY_X` / `OVERLAY_Y` | `10` / `10` | オーバーレイ位置 (px) |

### ログ確認

```bash
journalctl -u srt-stats-collector -f    # Stats Collector
journalctl -u srtla-ip-mapper -f        # IP Mapper (ポート→IP解決)
journalctl -u srt-relay-debug@srt -f    # デバッグリレー (ffmpeg)

# IP マッピング確認
cat /tmp/srtla-ip-map
```

### 注意事項

- x264 再エンコードを行うため **CPU 負荷が発生する** (ultrafast + 30fps で8コア中1-2コア程度)
- 入力ストリームのパケットロスが激しい場合、**キーフレーム受信までエンコードが開始されない** (数十秒かかることがある)
- RTMP出力に変更する場合は env ファイルの `OUTPUT_URL` / `OUTPUT_FORMAT` をコメントアウトを切り替える

## 接続URL

| 用途 | URL |
|------|------|
| SRTLA配信 (BELABOX) | srtla://unc-streaming-01:5000 |
| SRT直接配信 (OBS等) | `srt://unc-streaming-01.seichi.internal:4001?streamid=publish/live/feed1` |
| SRT視聴 | `srt://unc-streaming-01.seichi.internal:4000?streamid=play/live/feed1` |
| デバッグ視聴 (統計オーバーレイ付き) | `srt://unc-streaming-01.seichi.internal:4003` |
| Stats API | http://unc-streaming-01:8181/stats |
