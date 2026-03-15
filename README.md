# unc-streaming-manifests

IRL 配信インフラのセットアップ・設定ファイル一式。
サーバー (unc-streaming-01) とクライアント (配信PC) の構成を管理する。

## 全体構成

```
配信クライアント (x86 PC / BELABOX)
  |  複数モバイル回線 (SRTLA)
  v
unc-streaming-01
  srtla_rec :5000  (SRTLA受信・集約)
    → srt_server :4002 (SRT配信サーバー)
      → :4000 (SRT視聴)
      → :8181 (Stats API)
      → ffmpeg (srt-relay@) → RTMP push → Twitch / YouTube 等
```

## ディレクトリ構成

```
.
├── server/    # サーバー側 (unc-streaming-01) のセットアップ
│   ├── README.md
│   ├── BUILD_PROCEDURES.md
│   ├── build-all.sh
│   ├── setup-services.sh
│   ├── *.template (設定テンプレート)
│   ├── scripts/ (運用スクリプト)
│   └── systemd/ (systemd ユニットファイル)
│
└── client/    # クライアント側 (配信PC) のセットアップ
    ├── README.md
    ├── BUILD_PROCEDURES.md
    ├── setup-source-routing.sh
    ├── *.template (設定テンプレート)
    ├── systemd/ (systemd ユニットファイル)
    └── docs/ (詳細ドキュメント)
```

## 注意事項

このリポジトリはパブリックです。以下の情報は絶対にコミットしないでください:

- グローバル IP アドレス
- API キー・ストリームキー・パスワード等の認証情報
- SSH 秘密鍵・証明書
- その他、外部から特定可能な機密情報

設定テンプレート (`*.template`) にはプレースホルダーを使用し、実際の値は各サーバー上の環境変数ファイルに記載してください。

## セットアップガイド

- **サーバー (unc-streaming-01)**: [server/README.md](server/README.md)
- **クライアント (配信PC)**: [client/README.md](client/README.md)

## 接続URL

| 用途 | URL |
|------|------|
| SRTLA配信 (BELABOX) | srtla://unc-streaming-01:5000 |
| SRT直接配信 (OBS等) | `srt://unc-streaming-01.seichi.internal:4001?streamid=publish/live/feed1` |
| SRT視聴 | `srt://unc-streaming-01.seichi.internal:4000?streamid=play/live/feed1` |
| デバッグ視聴 (統計オーバーレイ付き) | `srt://unc-streaming-01.seichi.internal:4003` |
| Stats API | http://unc-streaming-01:8181/stats |
