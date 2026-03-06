# SRTLA クライアントセットアップガイド

x86 PC を SRTLA 配信クライアントとして構築する手順。
複数のネットワーク回線を束ねて、unc-streaming-01 に配信ストリームを送信する。

## 前提

- OS: Ubuntu 24.04 LTS
- 参考ハードウェア: ThinkPad T470 (i5-7300U / 8GB RAM)
  - Intel Quick Sync Video (VAAPI) によるハードウェアエンコード対応
  - ソフトウェアエンコード (x264) は 2C/4T では 1080p60 に不十分なため、**ハードウェアエンコード必須**

## アーキテクチャ

```
映像ソース (カメラ / キャプチャカード)
  |
  v
OBS Studio (VAAPI H.264 エンコード)
  |  SRT → localhost:9000
  v
srtla_send (複数NICでボンディング送信)
  |  NIC1 (Wi-Fi / 有線)
  |  NIC2 (USBテザリング / モバイルルーター)
  |  NIC3 (...)
  v
unc-streaming-01 srtla_rec:5000
```

## 1. 基本パッケージインストール

```bash
sudo apt update
sudo apt install -y \
    build-essential cmake git pkg-config \
    vainfo intel-media-va-driver-non-free \
    obs-studio ffmpeg \
    iproute2 net-tools
```

### VAAPI動作確認

```bash
vainfo
```

`VAProfileH264High` と `VAEntrypointEncSlice` が表示されればハードウェアエンコード可能。

出力例:
```
libva info: VA-API version 1.20.0
...
VAProfileH264High               : VAEntrypointEncSlice
```

## 2. srtla_send ビルド

```bash
sudo mkdir -p /opt/irl-srt && cd /opt/irl-srt

git clone --branch main --depth 1 https://github.com/irlserver/srtla.git
cd srtla
git submodule update --init
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)

sudo install -m 0755 srtla_send /usr/local/bin/srtla_send
```

## 3. ネットワーク設定 (ソースルーティング)

srtla_send が複数の NIC を使い分けるには、NIC ごとにソースルーティングを設定する必要がある。

### 3.1 ルーティングテーブル定義

```bash
# /etc/iproute2/rt_tables に追加
echo "101 mobile1" | sudo tee -a /etc/iproute2/rt_tables
echo "102 mobile2" | sudo tee -a /etc/iproute2/rt_tables
```

### 3.2 ソースルーティング設定スクリプト

```bash
#!/usr/bin/env bash
# /usr/local/bin/setup-source-routing.sh
# 各NICのIP/GW/デバイス名は環境に合わせて変更すること

set -euo pipefail

# NIC1: USBテザリング (例: usb0, 192.168.42.x)
if ip link show usb0 &>/dev/null; then
    NIC1_IP=$(ip -4 addr show usb0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    NIC1_GW=$(ip route show dev usb0 | grep default | awk '{print $3}')
    ip rule add from "$NIC1_IP" table mobile1 2>/dev/null || true
    ip route replace default via "$NIC1_GW" dev usb0 table mobile1
    echo "NIC1 (usb0): $NIC1_IP via $NIC1_GW"
fi

# NIC2: 別のモバイル回線 (例: usb1, enx*)
# 同様に追加...

echo "Source routing configured."
```

```bash
sudo chmod +x /usr/local/bin/setup-source-routing.sh
```

### 3.3 NetworkManager との共存

Ubuntu Desktop の NetworkManager がルーティングを上書きする場合がある。
USBテザリングデバイスは unmanaged にするか、nmcli で個別設定する:

```bash
# 例: usb0 を NetworkManager の管理外にする
sudo nmcli device set usb0 managed no
```

## 4. srtla_send の使い方

```bash
srtla_send --srtla_addr <unc-streaming-01のグローバルIP> \
           --srtla_port 5000 \
           --srt_port 9000 \
           --conn usb0 \
           --conn wlan0 \
           --log_level info
```

| オプション | 説明 |
|---|---|
| `--srtla_addr` | srtla_rec のアドレス (unc-streaming-01 のグローバルIP) |
| `--srtla_port` | srtla_rec のポート (5000) |
| `--srt_port` | ローカルで SRT を受け付けるポート (OBS の出力先) |
| `--conn` | 使用するネットワークインターフェース (複数指定可) |

## 5. OBS Studio 設定

### 5.1 出力設定

- 出力モード: 詳細
- エンコーダ: **FFmpeg VAAPI H.264** (ハードウェアエンコード)
  - OBS 30+ では `FFMPEG VAAPI H.264` を選択
  - デバイス: `/dev/dri/renderD128`
- ビットレート: 4500-6000 Kbps (回線帯域に応じて調整)
- キーフレーム間隔: 2秒
- プロファイル: High
- レート制御: CBR

### 5.2 配信設定

- サービス: カスタム
- サーバー: `srt://localhost:9000?mode=caller&latency=200000`
- ストリームキー: (空欄)

### 5.3 映像設定

- 基本解像度: 1920x1080
- 出力解像度: 1920x1080
- FPS: 60

### 5.4 パフォーマンス目安 (i5-7300U)

| 解像度 | エンコーダ | CPU使用率 | 備考 |
|---|---|---|---|
| 1080p60 | VAAPI H.264 | 10-20% | 推奨 |
| 1080p60 | x264 ultrafast | 90-100% | フレーム落ち発生、非推奨 |
| 720p60 | VAAPI H.264 | 5-10% | 回線帯域が限られる場合 |
| 720p60 | x264 veryfast | 50-70% | VAAPI非対応時の代替 |

## 6. systemd サービス化

### srtla-send.service

```ini
[Unit]
Description=SRTLA Sender
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/srtla-send/srtla-send.env
ExecStartPre=/usr/local/bin/setup-source-routing.sh
ExecStart=/usr/local/bin/srtla_send \
    --srtla_addr ${SRTLA_ADDR} \
    --srtla_port ${SRTLA_PORT} \
    --srt_port ${SRT_PORT} \
    --conn ${CONN1} \
    --conn ${CONN2} \
    --log_level info
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### /etc/srtla-send/srtla-send.env

```bash
SRTLA_ADDR=<unc-streaming-01のグローバルIP>
SRTLA_PORT=5000
SRT_PORT=9000
CONN1=usb0
CONN2=wlan0
```

```bash
sudo mkdir -p /etc/srtla-send
sudo cp srtla-send.env /etc/srtla-send/
sudo chmod 0640 /etc/srtla-send/srtla-send.env
sudo cp srtla-send.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable srtla-send
```

## 7. 動作確認チェックリスト

- [ ] `vainfo` でVAAPI対応を確認
- [ ] srtla_send がビルドできた
- [ ] 複数NICが認識されている (`ip link`)
- [ ] ソースルーティングが設定されている (`ip rule list`)
- [ ] srtla_send が起動し、各NICからパケットが出ている
- [ ] OBS から localhost:9000 に SRT 配信できる
- [ ] unc-streaming-01 の srtla_rec がストリームを受信している
- [ ] srt_server の Stats API (`curl http://unc-streaming-01:8181/stats`) でストリームが見える

## トラブルシューティング

### VAAPI が使えない
```bash
# ドライバの確認
sudo apt install intel-media-va-driver-non-free
# 権限確認
ls -la /dev/dri/renderD128
# video グループに追加
sudo usermod -aG video $USER
```

### srtla_send が NIC にバインドできない
- ソースルーティングが正しく設定されているか確認
- `ip route get <srtla_rec IP> from <NIC IP>` で経路確認
- NetworkManager がルーティングを上書きしていないか確認

### OBS で SRT 接続エラー
- srtla_send が起動しているか確認
- SRT URL の `mode=caller` を確認
- ポート番号が srtla_send の `--srt_port` と一致しているか確認
