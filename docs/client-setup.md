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
映像ソース (Cam Link 4K /dev/video2)
  |
  v
FFmpeg (VAAPI H.264 エンコード) or OBS Studio
  |  SRT → localhost:9000
  v
srtla_send (ips_file で複数NIC指定)
  |  NIC1 (Wi-Fi: wlp4s0)
  |  NIC2 (有線: enp0s31f6)
  |  NIC3 (USBテザリング: usb0)
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
    iproute2 net-tools \
    v4l-utils
```

### video グループへの追加

VAAPI デバイス (`/dev/dri/renderD128`) へのアクセス権限が必要。

```bash
sudo usermod -aG video $USER
```

> 反映にはログアウト/ログインが必要。

### VAAPI動作確認

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
また、srtla_send は `ips_file` で使用するソースIPを指定するため、ルーティング設定と合わせて ips_file を生成する。

### 3.1 ルーティングテーブル定義

```bash
# /etc/iproute2/rt_tables に追加
echo "100 wifi" | sudo tee -a /etc/iproute2/rt_tables
echo "101 mobile1" | sudo tee -a /etc/iproute2/rt_tables
echo "102 mobile2" | sudo tee -a /etc/iproute2/rt_tables
```

### 3.2 ソースルーティング設定スクリプト

このスクリプトは、各 NIC のソースルーティングを設定し、srtla_send 用の ips_file を生成する。

対応デバイス:
- `wlp4s0` — Wi-Fi (`wifi` テーブルでソースルーティング)
- `enp0s31f6` — 有線 LAN
- `enx*` — iOS USB テザリング (iPhone / iPad)
- `usb*` — Android USB テザリング

iOS USB テザリングは全デバイスが同じ `172.20.10.2/28` を割り当てるため、2台目以降はダミーインターフェース + SNAT で仮想IPを付与して分離する。

```bash
#!/usr/bin/env bash
# /usr/local/bin/setup-source-routing.sh
# srtla_send 用の ips_file を生成し、ソースルーティングを設定する
#
# 対応インターフェース:
#   wlp4s0       - Wi-Fi (wifi テーブルでソースルーティング)
#   enp0s31f6    - 有線LAN (mobile1 テーブル)
#   enx*         - iOS USB テザリング等 (mobile1/mobile2 テーブル)
#                  同一IPの場合はダミーIF + SNAT で分離
#   usb0         - Android USB テザリング (mobile1/mobile2 テーブル)

set -euo pipefail

IPS_FILE="/etc/srtla-send/srtla_ips"
MOBILE_TABLES=(mobile1 mobile2)
DUMMY_IP_BASE="10.200"  # ダミーIP用プレフィクス

> "$IPS_FILE"

# 既存のソースルーティングルールをクリーンアップ (再実行時の重複防止)
for table in wifi mobile1 mobile2; do
    while ip rule del table "$table" 2>/dev/null; do :; done
done

mobile_idx=0   # 次に使う mobile テーブルのインデックス
dummy_idx=0    # ダミーIF の連番
declare -A used_ips  # IP重複検出用

# --- ヘルパー関数 ---

get_ip() {
    ip -4 addr show "$1" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1
}

get_gw() {
    ip route show dev "$1" 2>/dev/null | grep default | awk '{print $3}' | head -1
}

is_active() {
    ip link show "$1" 2>/dev/null | grep -q 'state UP' &&
    ip -4 addr show "$1" 2>/dev/null | grep -q 'inet '
}

add_mobile_route() {
    local dev="$1" ip="$2" gw="$3"
    if (( mobile_idx >= ${#MOBILE_TABLES[@]} )); then
        echo "WARNING: No more mobile routing tables available, skipping $dev" >&2
        return 1
    fi
    local table="${MOBILE_TABLES[$mobile_idx]}"
    ip rule add from "$ip" table "$table" 2>/dev/null || true
    ip route replace default via "$gw" dev "$dev" table "$table"
    echo "$ip" >> "$IPS_FILE"
    echo "$dev: $ip via $gw (table $table)"
    (( mobile_idx++ )) || true
}

add_snat_route() {
    local dev="$1" real_ip="$2" gw="$3"
    if (( mobile_idx >= ${#MOBILE_TABLES[@]} )); then
        echo "WARNING: No more mobile routing tables available, skipping $dev" >&2
        return 1
    fi
    local table="${MOBILE_TABLES[$mobile_idx]}"
    local dummy_name="dummy-m${dummy_idx}"
    local virtual_ip="${DUMMY_IP_BASE}.${dummy_idx}.1"

    ip link add "$dummy_name" type dummy 2>/dev/null || true
    ip link set "$dummy_name" up
    ip addr replace "$virtual_ip/32" dev "$dummy_name"

    ip rule add from "$virtual_ip" table "$table" 2>/dev/null || true
    ip route replace default via "$gw" dev "$dev" table "$table"
    iptables -t nat -C POSTROUTING -s "$virtual_ip" -o "$dev" -j SNAT --to-source "$real_ip" 2>/dev/null ||
    iptables -t nat -A POSTROUTING -s "$virtual_ip" -o "$dev" -j SNAT --to-source "$real_ip"

    echo "$virtual_ip" >> "$IPS_FILE"
    echo "$dev: $virtual_ip -> SNAT $real_ip via $gw (table $table, dummy $dummy_name)"
    (( mobile_idx++ )) || true
    (( dummy_idx++ )) || true
}

# --- メイン処理 ---

# 1. Wi-Fi (wlp4s0) - wifi テーブルでソースルーティング
# テザリングデバイスがデフォルトルートを奪うため、WiFi にも明示的なソースルーティングが必要
if is_active wlp4s0; then
    WLP_IP=$(get_ip wlp4s0)
    WLP_GW=$(get_gw wlp4s0)
    if [[ -n "$WLP_GW" ]]; then
        ip route replace default via "$WLP_GW" dev wlp4s0 table wifi
        ip rule add from "$WLP_IP" table wifi 2>/dev/null || true
        echo "$WLP_IP" >> "$IPS_FILE"
        used_ips["$WLP_IP"]=wlp4s0
        echo "wlp4s0: $WLP_IP via $WLP_GW (table wifi)"
    fi
fi

# 2. 有線 (enp0s31f6)
if is_active enp0s31f6; then
    ETH_IP=$(get_ip enp0s31f6)
    ETH_GW=$(get_gw enp0s31f6)
    if [[ -n "$ETH_GW" ]]; then
        used_ips["$ETH_IP"]=enp0s31f6
        add_mobile_route enp0s31f6 "$ETH_IP" "$ETH_GW"
    fi
fi

# 3. iOS USB テザリング (enx*) + Android (usb*)
for dev in $(ip -o link show | grep -oP '(enx[0-9a-f]+|usb\d+)(?=:)' | sort); do
    if ! is_active "$dev"; then
        continue
    fi

    DEV_IP=$(get_ip "$dev")
    DEV_GW=$(get_gw "$dev")

    if [[ -z "$DEV_GW" ]]; then
        DEV_SUBNET=$(echo "$DEV_IP" | grep -oP '^\d+\.\d+\.\d+')
        DEV_GW="${DEV_SUBNET}.1"
    fi

    if [[ -z "${used_ips[$DEV_IP]+_}" ]]; then
        used_ips["$DEV_IP"]="$dev"
        add_mobile_route "$dev" "$DEV_IP" "$DEV_GW"
    else
        echo "$dev: IP $DEV_IP conflicts with ${used_ips[$DEV_IP]}, using SNAT"
        add_snat_route "$dev" "$DEV_IP" "$DEV_GW"
    fi
done

killall -HUP srtla_send 2>/dev/null || true
echo "Source routing configured. IPs in $IPS_FILE:"
cat "$IPS_FILE"
```

```bash
sudo chmod +x /usr/local/bin/setup-source-routing.sh
```

> **iOS USB テザリングの IP 重複について**: iPhone/iPad の USB テザリングはすべて `172.20.10.0/28` を使い、クライアントに `172.20.10.2` を割り当てる。2台以上接続した場合、スクリプトは2台目以降にダミーインターフェース (`dummy-m0` 等) と仮想IP (`10.200.0.1` 等) を割り当て、iptables SNAT で実IPに変換してルーティングする。

### 3.3 NetworkManager との共存

Ubuntu Desktop の NetworkManager がルーティングを上書きする場合がある。
USBテザリングデバイスは unmanaged にするか、nmcli で個別設定する:

```bash
# 例: usb0 を NetworkManager の管理外にする
sudo nmcli device set usb0 managed no
```

## 4. srtla_send の使い方

```bash
srtla_send [--help] [--version] [--verbose] <listen_port> <srtla_host> <srtla_port> [ips_file]
```

| 引数 | 説明 |
|---|---|
| `listen_port` | ローカルで SRT を受け付けるポート (OBS/FFmpeg の出力先) |
| `srtla_host` | srtla_rec のアドレス (unc-streaming-01 のグローバルIP) |
| `srtla_port` | srtla_rec のポート (5000) |
| `ips_file` | 使用するソースIPを列挙したファイル (省略時はデフォルト `/tmp/srtla_ips`) |

| オプション | 説明 |
|---|---|
| `--help` | ヘルプを表示 |
| `--verbose` | 詳細ログを出力 |
| `--version` | バージョンを表示 |

### ips_file の形式

1行に1つのソースIPアドレスを記載する:

```
192.168.1.100
192.168.42.129
10.0.0.5
```

srtla_send は SIGHUP を受け取ると ips_file を再読み込みし、回線構成を動的に変更できる。

### 実行例

```bash
srtla_send 9000 <unc-streaming-01のグローバルIP> 5000 /etc/srtla-send/srtla_ips
```

## 5. 映像キャプチャ・エンコード設定

### 5.1 FFmpeg ヘッドレスキャプチャ (推奨)

Cam Link 4K 等の V4L2 デバイスから映像をキャプチャし、VAAPI H.264 でエンコードして SRT 送信する。
ヘッドレス (デスクトップ環境不要) で動作するため、サーバー的な運用に適している。

#### デバイスパス確認

```bash
v4l2-ctl --list-devices
```

Cam Link 4K の場合、複数の `/dev/videoX` が表示されるが、映像キャプチャ用のデバイスを使用する。
`v4l2-ctl -d /dev/videoX --list-formats-ext` で対応フォーマットを確認できる。

#### FFmpeg コマンド例

```bash
ffmpeg -nostdin \
    -vaapi_device /dev/dri/renderD128 \
    -f v4l2 -input_format nv12 -video_size 1920x1080 -framerate 60 \
    -i /dev/video2 \
    -f alsa -i hw:1,0 \
    -vf 'format=nv12,hwupload' \
    -c:v h264_vaapi -b:v 4500k \
    -g 120 -keyint_min 120 -profile:v 100 \
    -c:a aac -b:a 128k \
    -f mpegts "srt://localhost:9000?mode=caller&latency=200000&streamid=publish/live/feed1"
```

> Cam Link 4K は映像 (`/dev/video2`, V4L2) と音声 (`hw:1,0`, ALSA) が別デバイスとして認識される。`arecord -l` でオーディオデバイス番号を確認すること。

#### srt-capture.service (systemd)

```ini
[Unit]
Description=FFmpeg V4L2 to SRT Capture (VAAPI H.264 + Audio)
After=srtla-send.service
Requires=srtla-send.service

[Service]
Type=simple
EnvironmentFile=/etc/srtla-send/srt-capture.env
ExecStart=/usr/bin/ffmpeg -nostdin \
    -vaapi_device ${VAAPI_DEVICE} \
    -f v4l2 \
    -input_format ${INPUT_FORMAT} \
    -video_size ${INPUT_RESOLUTION} \
    -framerate ${INPUT_FPS} \
    -i ${CAPTURE_DEVICE} \
    -f alsa \
    -i ${AUDIO_DEVICE} \
    -vf 'format=nv12,hwupload' \
    -c:v h264_vaapi \
    -b:v ${BITRATE} \
    -g ${KEYFRAME_INTERVAL} \
    -keyint_min ${KEYFRAME_INTERVAL} \
    -profile:v ${H264_PROFILE} \
    -c:a aac \
    -b:a ${AUDIO_BITRATE} \
    -f mpegts \
    ${SRT_OUTPUT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

#### /etc/srtla-send/srt-capture.env

```bash
CAPTURE_DEVICE=/dev/video2
INPUT_FORMAT=nv12
INPUT_RESOLUTION=1920x1080
INPUT_FPS=60
VAAPI_DEVICE=/dev/dri/renderD128
BITRATE=4500k
KEYFRAME_INTERVAL=120
H264_PROFILE=100
AUDIO_DEVICE=hw:1,0
AUDIO_BITRATE=128k
SRT_OUTPUT="srt://localhost:9000?mode=caller&latency=200000&streamid=publish/live/feed1"
```

> **重要**: `streamid=publish/live/feed1` は必須。これがないと srt-live-server が publisher を識別できず、ストリームが配信先に到達しない。OBS の場合も同様に SRT URL に `&streamid=publish/live/feed1` を付与するか、ストリームキー欄に `#!::r=publish/live/feed1,m=publish` を設定する。

```bash
sudo cp srt-capture.env /etc/srtla-send/
sudo chmod 0640 /etc/srtla-send/srt-capture.env
sudo cp srt-capture.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable srt-capture
```

### 5.2 OBS Studio 設定 (デスクトップ環境使用時)

デスクトップ環境がある場合は OBS Studio も利用可能。

#### 出力設定

- 出力モード: 詳細
- エンコーダ: **FFmpeg VAAPI H.264** (ハードウェアエンコード)
  - OBS 30+ では `FFMPEG VAAPI H.264` を選択
  - デバイス: `/dev/dri/renderD128`
- ビットレート: 4500-6000 Kbps (回線帯域に応じて調整)
- キーフレーム間隔: 2秒
- プロファイル: High
- レート制御: CBR

#### 配信設定

- サービス: カスタム
- サーバー: `srt://localhost:9000?mode=caller&latency=200000&streamid=publish/live/feed1`
- ストリームキー: (空欄、streamid を URL に含めない場合は `#!::r=publish/live/feed1,m=publish` を設定)

#### 映像設定

- 基本解像度: 1920x1080
- 出力解像度: 1920x1080
- FPS: 60

### 5.3 パフォーマンス目安 (i5-7300U)

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
ExecStart=/usr/local/bin/srtla_send ${SRT_PORT} ${SRTLA_ADDR} ${SRTLA_PORT} ${IPS_FILE}
ExecReload=/bin/kill -HUP $MAINPID
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
IPS_FILE=/etc/srtla-send/srtla_ips
```

```bash
sudo mkdir -p /etc/srtla-send
sudo cp srtla-send.env /etc/srtla-send/
sudo chmod 0640 /etc/srtla-send/srtla-send.env
sudo cp srtla-send.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable srtla-send
```

## 7. Stats API (ストリーム状態確認)

unc-streaming-01 の srt-live-server は HTTP API を提供しており、配信ストリームの状態を確認できる。

### エンドポイント

```
GET http://unc-streaming-01.seichi.internal:8181/stats
```

### 認証

`Authorization` ヘッダーに API キーを指定する。API キーは `/etc/srt-live-server/sls.conf` の `api_keys` ディレクティブで設定する。

```nginx
# /etc/srt-live-server/sls.conf (srt {} ブロック内)
api_keys <your-api-key>;

# 複数キーはカンマ区切り
# api_keys key1,key2,key3;
```

設定変更後は `sudo systemctl restart srt-live-server` で反映。

### アクセス方法

```bash
# curl
curl -H 'Authorization: <your-api-key>' http://unc-streaming-01.seichi.internal:8181/stats

# ブラウザから確認する場合は ModHeader 等の拡張機能で Authorization ヘッダーを付与するか、
# DevTools コンソールから:
# fetch('/stats', { headers: { 'Authorization': '<your-api-key>' } }).then(r => r.json()).then(console.log)
```

### レスポンス例

```json
{
  "publishers": {
    "publish/live/feed1": {
      "bitrate": 4962,
      "bytesRcvDrop": 0,
      "bytesRcvLoss": 0,
      "latency": 200,
      "mbpsBandwidth": 542.556,
      "mbpsRecvRate": 4.546,
      "msRcvBuf": 182,
      "pktRcvDrop": 0,
      "pktRcvLoss": 0,
      "rtt": 12.702,
      "uptime": 13
    }
  },
  "status": "ok"
}
```

| フィールド | 説明 |
|---|---|
| `bitrate` | 受信ビットレート (kbps) |
| `latency` | 設定レイテンシ (ms) |
| `rtt` | ラウンドトリップタイム (ms) |
| `pktRcvLoss` | 受信パケットロス数 |
| `pktRcvDrop` | 受信パケットドロップ数 |
| `uptime` | ストリーム継続時間 (秒) |
| `mbpsRecvRate` | 受信レート (Mbps) |
| `mbpsBandwidth` | 推定帯域幅 (Mbps) |
| `msRcvBuf` | 受信バッファ (ms) |

## 8. 動作確認チェックリスト

- [ ] `vainfo --display drm --device /dev/dri/renderD128` でVAAPI対応を確認
- [ ] srtla_send がビルドできた
- [ ] 複数NICが認識されている (`ip link`)
- [ ] ソースルーティングが設定されている (`ip rule list`)
- [ ] ips_file が生成されている (`cat /etc/srtla-send/srtla_ips`)
- [ ] srtla_send が起動し、各NICからパケットが出ている
- [ ] srt-capture.service が起動し、映像をキャプチャできている (FFmpeg 使用時)
- [ ] OBS から localhost:9000 に SRT 配信できる (OBS 使用時)
- [ ] unc-streaming-01 の srtla_rec がストリームを受信している
- [ ] srt_server の Stats API でストリームが見える (`curl -H 'Authorization: <api-key>' http://unc-streaming-01.seichi.internal:8181/stats`)

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
- ips_file にNICのIPが正しく記載されているか確認
- ソースルーティングが正しく設定されているか確認
- `ip route get <srtla_rec IP> from <NIC IP>` で経路確認
- NetworkManager がルーティングを上書きしていないか確認

### OBS / FFmpeg で SRT 接続エラー
- srtla_send が起動しているか確認
- SRT URL の `mode=caller` を確認
- ポート番号が srtla_send の listen_port と一致しているか確認

### srtla_send が Release ビルドで異常動作する (assert バグ)

上流の srtla リポジトリの `sender.cpp` には、`assert()` の内部で副作用のある関数呼び出し (`get_seconds()`, `get_ms()`) を行っている箇所がある。`-DCMAKE_BUILD_TYPE=Release` でビルドすると `-DNDEBUG` が定義され、`assert()` がマクロ展開で消えるため、時刻変数が未初期化のまま使用される。

**症状**: srtla_send が即座にクラッシュする、または接続のハウスキーピングが正常に動作しない。

**対処法**: `sender.cpp` の該当箇所を修正し、関数呼び出しを assert の外に出す:

```cpp
// 修正前 (NG: Release ビルドで消える)
assert(get_seconds(&t) == 0);

// 修正後 (OK)
{ int _ret = get_seconds(&t); assert(_ret == 0); (void)_ret; }
```

該当箇所は L181 (`get_seconds`) と L602 (`get_ms`) の2箇所。修正後は再ビルドして `srtla_send` を再配置する。

> **注意**: `assert()` 内に副作用のあるコード (関数呼び出し、代入など) を入れてはならない。Release ビルド (`-DNDEBUG`) で assert が無効化されると副作用ごと消える。

### Cam Link 4K が認識されない
```bash
# デバイス一覧
v4l2-ctl --list-devices
# 対応フォーマット確認
v4l2-ctl -d /dev/video2 --list-formats-ext
# カーネルログ確認
dmesg | grep -i cam
```
