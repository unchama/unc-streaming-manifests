# SRTLA 配信クライアントセットアップ

x86 PC を SRTLA 配信クライアントとして構築する。
複数のネットワーク回線を束ねて、unc-streaming-01 に配信ストリームを送信する。

## 前提

- OS: Ubuntu 24.04 LTS
- 参考ハードウェア: ThinkPad T470 (i5-7300U / 8GB RAM)
  - Intel Quick Sync Video (VAAPI) によるハードウェアエンコード対応
  - ソフトウェアエンコード (x264) は 2C/4T では 1080p60 に不十分なため、**ハードウェアエンコード必須**

## アーキテクチャ

```
映像ソース
  |  A) Cam Link 4K (/dev/camlink, V4L2)
  |     → FFmpeg (VAAPI H.264 エンコード) or OBS Studio
  |  B) GoPro Webcam (UDP mpegts via USB Ethernet)
  |     → FFmpeg (H.264 copy, エンコード不要)
  |
  |  SRT → localhost:9000
  v
srtla_send (ips_file で複数NIC指定)
  |  NIC1 (Wi-Fi: wlp4s0 — iPhoneテザリング等)
  |  NIC2 (USB: enx* — モバイルルーター)
  |  NIC3 (有線: enp0s31f6)
  v
unc-streaming-01 srtla_rec:5000
```

## ファイル構成

```
client/
  README.md                        ← このファイル
  BUILD_PROCEDURES.md              ← srtla_send ビルド手順
  setup-source-routing.sh          ← ソースルーティング設定スクリプト
  90-camlink.rules                 ← Cam Link 4K udev ルール
  srtla-send.env.template          ← srtla-send 環境変数テンプレート
  srt-capture.env.template         ← FFmpeg キャプチャ環境変数テンプレート
  srt-capture-gopro.env.template   ← GoPro キャプチャ環境変数テンプレート
  systemd/
    srtla-send.service             ← srtla_send systemd ユニット
    srt-capture.service            ← FFmpeg キャプチャ systemd ユニット
    srt-capture-gopro.service      ← GoPro キャプチャ systemd ユニット
  NetworkManager/
    90-srtla-routing.sh            ← NIC 増減時のソースルーティング自動再設定
  docs/
    network-setup.md               ← ネットワーク設定 (ソースルーティング)
    capture-setup.md               ← 映像キャプチャ・エンコード設定
    tailscale.md                   ← Tailscale (リモートアクセス)
    sleep-disable.md               ← スリープ / サスペンド無効化
    stats-api.md                   ← Stats API (ストリーム状態確認)
    troubleshooting.md             ← トラブルシューティング
```

## セットアップ手順

### 1. 基本パッケージインストール

```bash
sudo apt update
sudo apt install -y \
    build-essential cmake git pkg-config \
    vainfo intel-media-va-driver-non-free \
    obs-studio ffmpeg \
    iproute2 net-tools \
    v4l-utils
```

#### video グループへの追加

VAAPI デバイス (`/dev/dri/renderD128`) へのアクセス権限が必要。

```bash
sudo usermod -aG video $USER
```

> 反映にはログアウト/ログインが必要。

#### VAAPI動作確認

```bash
vainfo --display drm --device /dev/dri/renderD128
```

> SSH 経由では `--display drm --device /dev/dri/renderD128` オプションが必要。ローカルコンソールでは `vainfo` のみでも動作する。

`VAProfileH264High` と `VAEntrypointEncSlice` が表示されればハードウェアエンコード可能。

出力例:
```
libva info: VA-API version 1.20.0
...
VAProfileH264High               : VAEntrypointEncSlice
```

### 2. srtla_send ビルド

[BUILD_PROCEDURES.md](BUILD_PROCEDURES.md) を参照。

### 3. ネットワーク設定

[docs/network-setup.md](docs/network-setup.md) を参照。

### 4. 映像キャプチャ設定

[docs/capture-setup.md](docs/capture-setup.md) を参照。

### 5. systemd サービス化

各サービスファイルとテンプレートを配置する。

```bash
# 設定ディレクトリ作成
sudo mkdir -p /etc/srtla-send

# 環境変数ファイルをコピー・編集
sudo cp srtla-send.env.template /etc/srtla-send/srtla-send.env
sudo cp srt-capture.env.template /etc/srtla-send/srt-capture.env        # Cam Link 4K 使用時
sudo cp srt-capture-gopro.env.template /etc/srtla-send/srt-capture-gopro.env  # GoPro 使用時
sudo chmod 0640 /etc/srtla-send/*.env

# 各 .env ファイルを編集して環境に合わせた値を設定する

# systemd ユニットファイルをコピー
sudo cp systemd/srtla-send.service /etc/systemd/system/
sudo cp systemd/srt-capture.service /etc/systemd/system/          # Cam Link 4K 使用時
sudo cp systemd/srt-capture-gopro.service /etc/systemd/system/    # GoPro 使用時

# ソースルーティングスクリプトを配置
sudo install -m 0755 setup-source-routing.sh /usr/local/bin/setup-source-routing.sh

# udev ルールを配置 (Cam Link 4K 使用時)
sudo cp 90-camlink.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=video4linux

# サービス有効化
sudo systemctl daemon-reload
sudo systemctl enable srtla-send
sudo systemctl enable srt-capture          # Cam Link 4K 使用時
sudo systemctl enable srt-capture-gopro    # GoPro 使用時
```

> **注意**: `srt-capture.service` (Cam Link 4K 用) と `srt-capture-gopro.service` は同時に起動しないこと。両方が `localhost:9000` に SRT 送信するため競合する。

### 6. Tailscale

[docs/tailscale.md](docs/tailscale.md) を参照。

### 7. スリープ無効化

[docs/sleep-disable.md](docs/sleep-disable.md) を参照。

### 8. Netdata (リアルタイムモニタリング)

CPU 使用率やネットワーク帯域をリアルタイムで監視するために Netdata をインストールする。

```bash
wget -qO- https://get.netdata.cloud/kickstart.sh | sudo bash -s -- --dont-wait --stable-channel
```

インストール後、`http://<ホスト名>:19999` でダッシュボードにアクセスできる。
ネットワークインターフェースの増減は自動検出される。

## 動作確認チェックリスト

- [ ] `vainfo --display drm --device /dev/dri/renderD128` でVAAPI対応を確認
- [ ] srtla_send がビルドできた
- [ ] 複数NICが認識されている (`ip link`)
- [ ] ソースルーティングが設定されている (`ip rule list`)
- [ ] ips_file が生成されている (`cat /etc/srtla-send/srtla_ips`)
- [ ] srtla_send が起動し、各NICからパケットが出ている
- [ ] srt-capture.service が起動し、映像をキャプチャできている (Cam Link 4K 使用時)
- [ ] srt-capture-gopro.service が起動し、GoPro からキャプチャできている (GoPro 使用時)
- [ ] GoPro のインターフェースが exclude_devs で除外されている (GoPro 使用時)
- [ ] OBS から localhost:9000 に SRT 配信できる (OBS 使用時)
- [ ] unc-streaming-01 の srtla_rec がストリームを受信している
- [ ] srt_server の Stats API でストリームが見える (`curl -H 'Authorization: <api-key>' http://unc-streaming-01.seichi.internal:8181/stats`)
- [ ] Tailscale 経由で SSH 接続できる (`ssh unchama@<tailscale-ip>`)
- [ ] Tailscale 導入後もソースルーティングが正常 (`ip rule list` で `from <IP> lookup wifi` が残っている)
- [ ] スリープ / サスペンドが無効化されている (`gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type` → `'nothing'`)

## 回線追加・削除

ips_file を編集して `systemctl reload srtla-send` を実行すると、srtla_send が SIGHUP を受け取り ips_file を再読み込みする。サービスの再起動は不要。

```bash
# 回線追加の例
echo "192.168.42.129" | sudo tee -a /etc/srtla-send/srtla_ips

# ソースルーティングも追加
sudo ip rule add from 192.168.42.129 table mobile1
sudo ip route replace default via 192.168.42.1 dev usb0 table mobile1

# srtla_send に反映
sudo systemctl reload srtla-send
```

回線を削除する場合は ips_file から該当行を削除して reload する。

## ルーターのポート転送設定

unc-streaming-01 がルーター配下にある場合、srtla_rec への UDP パケットを転送する設定が必要。

- プロトコル: **UDP**
- 外部ポート: **5000**
- 転送先: unc-streaming-01 のローカルIP
- 転送先ポート: **5000**

## 関連ドキュメント

- [Stats API (ストリーム状態確認)](docs/stats-api.md)
- [トラブルシューティング](docs/troubleshooting.md)
- [外配信チェックリスト](docs/irl-streaming-checklist.md)
- [SRT バッファチューニング](docs/srt-buffer-tuning.md)
