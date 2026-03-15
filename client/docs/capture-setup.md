# 映像キャプチャ・エンコード設定

## FFmpeg ヘッドレスキャプチャ (推奨)

Cam Link 4K 等の V4L2 デバイスから映像をキャプチャし、VAAPI H.264 でエンコードして SRT 送信する。
ヘッドレス (デスクトップ環境不要) で動作するため、サーバー的な運用に適している。

### デバイスパス確認

```bash
v4l2-ctl --list-devices
```

Cam Link 4K の場合、複数の `/dev/videoX` が表示されるが、映像キャプチャ用のデバイスを使用する。
`v4l2-ctl -d /dev/videoX --list-formats-ext` で対応フォーマットを確認できる。

### udev ルールによるデバイスパス固定

USB キャプチャデバイスは接続順で `/dev/videoX` の番号が変わる。udev ルールでシンボリックリンクを作成して固定する。

udev ルールファイルは [`../90-camlink.rules`](../90-camlink.rules) にある。

```bash
sudo cp ../90-camlink.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=video4linux

# 確認
ls -la /dev/camlink
```

これにより `/dev/camlink` が常に Cam Link 4K の映像デバイスを指す。環境変数ファイルでは `CAPTURE_DEVICE=/dev/camlink` を指定する。

> 他のキャプチャデバイスを使う場合は `udevadm info -a /dev/videoX` で `ATTR{name}` を確認し、ルールを追加する。

### FFmpeg コマンド例

```bash
ffmpeg -nostdin \
    -vaapi_device /dev/dri/renderD128 \
    -f v4l2 -input_format nv12 -video_size 1920x1080 -framerate 60 \
    -i /dev/camlink \
    -f alsa -i hw:1,0 \
    -vf 'format=nv12,hwupload' \
    -c:v h264_vaapi -b:v 4500k \
    -g 120 -keyint_min 120 -profile:v 100 \
    -c:a aac -b:a 128k \
    -f mpegts "srt://localhost:9000?mode=caller&latency=1000000&streamid=publish/live/feed1"
```

> Cam Link 4K は映像 (`/dev/camlink`, V4L2) と音声 (`hw:1,0`, ALSA) が別デバイスとして認識される。`arecord -l` でオーディオデバイス番号を確認すること。

### systemd サービス

systemd ユニットファイルは [`../systemd/srt-capture.service`](../systemd/srt-capture.service) にある。
環境変数テンプレートは [`../srt-capture.env.template`](../srt-capture.env.template) にある。

> **重要**: `streamid=publish/live/feed1` は必須。これがないと srt-live-server が publisher を識別できず、ストリームが配信先に到達しない。OBS の場合も同様に SRT URL に `&streamid=publish/live/feed1` を付与するか、ストリームキー欄に `#!::r=publish/live/feed1,m=publish` を設定する。

### セットアップ

```bash
sudo cp ../srt-capture.env.template /etc/srtla-send/srt-capture.env
sudo chmod 0640 /etc/srtla-send/srt-capture.env
# /etc/srtla-send/srt-capture.env を編集して環境に合わせた値を設定する

sudo cp ../systemd/srt-capture.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable srt-capture
```

## GoPro ウェブカメラキャプチャ

GoPro (HERO10 以降) を USB 接続してウェブカメラモードで使用する。GoPro は USB Ethernet (RNDIS) として認識され、HTTP API でウェブカメラモードを起動すると H.264 エンコード済みの mpegts ストリームを UDP で配信する。再エンコード不要で CPU 負荷が低い。

**制約:**
- 出力は **1080p25** 固定（60fps は不可）
- 長時間使用は発熱リスクあり（給電しながらだと特に）
- GoPro の USB Ethernet インターフェース (`enx*`) を srtla ボンディングから除外する必要がある（[network-setup.md のデバイス除外](network-setup.md#デバイス除外-exclude_devs) を参照）

### GoPro USB 接続確認

GoPro を USB-C で接続すると、USB Ethernet インターフェースが作成される:

```bash
# USB デバイスとして認識されているか
lsusb | grep GoPro
# Bus 001 Device 052: ID 2672:0056 GoPro HERO10 Black

# USB Ethernet インターフェース確認
ip -4 addr show | grep enx
# enx2474f75480b3: inet 172.23.114.52/24 ...
```

GoPro 本体は `172.2x.xxx.51` にいる（IP はモデルにより異なる）。

### ウェブカメラモード起動

```bash
# ステータス確認
wget -qO- http://172.23.114.51:8080/gopro/webcam/status
# {"status": 1, "error": 0}  → 1=IDLE

# ウェブカメラモード開始
wget -qO- http://172.23.114.51:8080/gopro/webcam/start
# {"status": 2, "error": 0}  → 2=READY (ストリーミング中)
```

### FFmpeg 受信確認

```bash
# テスト受信 (5秒で終了)
timeout 5 ffmpeg -nostdin -f mpegts -i 'udp://172.23.114.51:8554' -frames:v 1 -f null /dev/null
```

`1920x1080, 25fps, H.264 + AAC 48kHz stereo` が表示されれば OK。

### systemd サービス

systemd ユニットファイルは [`../systemd/srt-capture-gopro.service`](../systemd/srt-capture-gopro.service) にある。
環境変数テンプレートは [`../srt-capture-gopro.env.template`](../srt-capture-gopro.env.template) にある。

### セットアップ

```bash
sudo cp ../srt-capture-gopro.env.template /etc/srtla-send/srt-capture-gopro.env
sudo chmod 0640 /etc/srtla-send/srt-capture-gopro.env
# /etc/srtla-send/srt-capture-gopro.env を編集して環境に合わせた値を設定する

sudo cp ../systemd/srt-capture-gopro.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable srt-capture-gopro
```

> **注意**: `srt-capture.service` (Cam Link 4K 用) と `srt-capture-gopro.service` は同時に起動しないこと。両方が `localhost:9000` に SRT 送信するため競合する。

## OBS Studio 設定 (デスクトップ環境使用時)

デスクトップ環境がある場合は OBS Studio も利用可能。

### 出力設定

- 出力モード: 詳細
- エンコーダ: **FFmpeg VAAPI H.264** (ハードウェアエンコード)
  - OBS 30+ では `FFMPEG VAAPI H.264` を選択
  - デバイス: `/dev/dri/renderD128`
- ビットレート: 4500-6000 Kbps (回線帯域に応じて調整)
- キーフレーム間隔: 2秒
- プロファイル: High
- レート制御: CBR

### 配信設定

- サービス: カスタム
- サーバー: `srt://localhost:9000?mode=caller&latency=1000000&streamid=publish/live/feed1`
- ストリームキー: (空欄、streamid を URL に含めない場合は `#!::r=publish/live/feed1,m=publish` を設定)

### 映像設定

- 基本解像度: 1920x1080
- 出力解像度: 1920x1080
- FPS: 60

## パフォーマンス目安 (i5-7300U)

| 解像度 | エンコーダ | CPU使用率 | 備考 |
|---|---|---|---|
| 1080p60 | VAAPI H.264 | 10-20% | 推奨 |
| 1080p60 | x264 ultrafast | 90-100% | フレーム落ち発生、非推奨 |
| 1080p25 | copy (GoPro) | 1-3% | GoPro ウェブカメラ、エンコード不要 |
| 720p60 | VAAPI H.264 | 5-10% | 回線帯域が限られる場合 |
| 720p60 | x264 veryfast | 50-70% | VAAPI非対応時の代替 |
