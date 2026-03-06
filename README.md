# unc-streaming-manifests

unc-streaming-01 のセットアップ・設定ファイル一式。

## 構成

```
配信クライアント (BELABOX等)
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
| IP | 192.168.3.26/22 (VLAN100) |
| Proxmoxホスト | unchama-sv-prox08 (VMID 202) |
| OS | Ubuntu 24.04 LTS |
| CPU / メモリ / ディスク | 4コア / 8GB / 50GB |

## 使用ソフトウェア

| ソフトウェア | バージョン | リポジトリ |
|---|---|---|
| libsrt (BELABOX fork) | v1.5.4 | [irlserver/srt](https://github.com/irlserver/srt) (belabox branch) |
| srtla | v1.0.0 | [irlserver/srtla](https://github.com/irlserver/srtla) |
| irl-srt-server | v3.1.0 | [irlserver/irl-srt-server](https://github.com/irlserver/irl-srt-server) |
| ffmpeg | 6.1.1 | apt (ubuntu 24.04) |

## ファイル構成

```
.
├── README.md                 # このファイル
├── BUILD_PROCEDURES.md       # 詳細ビルド手順書
├── build-all.sh              # 自動ビルドスクリプト (srt + srtla + irl-srt-server)
├── setup-services.sh         # systemdサービスインストールスクリプト
├── sls.conf.template         # srt_server設定ファイル
├── relay.env.template        # ffmpegリレー用環境変数テンプレート
└── systemd/
    ├── srtla-rec.service         # srtla_rec systemdユニット
    ├── srt-live-server.service   # srt_server systemdユニット
    └── srt-relay@.service        # ffmpegリレー テンプレートユニット
```

## セットアップ手順

### 1. ビルド
```bash
sudo ./build-all.sh
```

### 2. サービスインストール
```bash
sudo ./setup-services.sh
```

### 3. サービス起動
```bash
sudo systemctl start srtla-rec
sudo systemctl start srt-live-server
```

### 4. リレー設定 (配信プラットフォームへの転送)
```bash
# ストリームキー設定
sudo nano /etc/srt-live-server/relay-twitch.env

# 有効化・起動
sudo systemctl enable --now srt-relay@twitch
```

## 接続URL

| 用途 | URL |
|------|------|
| SRTLA配信 (BELABOX) | srtla://unc-streaming-01:5000 |
| SRT直接配信 (OBS等) | `srt://unc-streaming-01:4001?streamid=publish/live/feed1` |
| SRT視聴 | `srt://unc-streaming-01:4000?streamid=play/live/feed1` |
| Stats API | http://unc-streaming-01:8181/stats |
