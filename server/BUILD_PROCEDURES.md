# IRL SRT スタック ビルド手順

## 概要

以下の3つのリポジトリを順番にビルドする:

1. **irlserver/srt** (belabox ブランチ) - BELABOX フォーク版 SRT ライブラリ
2. **irlserver/srtla** (main ブランチ) - SRTLA プロキシ (srtla_rec)
3. **irlserver/irl-srt-server** (main ブランチ) - SRT Live Server

## システム依存パッケージ (apt)

```
build-essential cmake git pkg-config libssl-dev tclsh
```

## ビルド順序と詳細

### 1. irlserver/srt (BELABOX フォーク)

- **ブランチ**: `belabox` (master/main ではない)
- **バージョン**: v1.5.4 (最新リリース: v1.5.4-irl2)
- **ビルドシステム**: CMake 2.8.12+
- **言語**: C/C++
- **主な依存**: OpenSSL (libssl-dev)
- **用途**: libsrt 共有/静的ライブラリを提供。srtla と irl-srt-server の両方で必要。

```bash
git clone --branch belabox --depth 1 https://github.com/irlserver/srt.git
cd srt && mkdir build && cd build
cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_ENCRYPTION=ON -DENABLE_APPS=OFF -DENABLE_SHARED=ON -DENABLE_STATIC=ON
make -j$(nproc)
sudo make install
sudo ldconfig
```

**主要な CMake オプション:**
- `ENABLE_ENCRYPTION=ON` - AES 暗号化 (OpenSSL が必要)
- `ENABLE_APPS=OFF` - サンプルアプリをスキップ (不要)
- `ENABLE_BONDING=OFF` - デフォルト OFF、サーバーでは不要
- `ENABLE_STDCXX_SYNC` - プラットフォーム依存のデフォルト値、通常はそのままでOK

**ビルド結果**: `libsrt.so`、`libsrt.a`、ヘッダー、pkg-config ファイルが `/usr/local` にインストールされる。

### 2. irlserver/srtla

- **ブランチ**: `main`
- **バージョン**: 1.0.0
- **ビルドシステム**: CMake 3.16+
- **言語**: C/C++17
- **依存**: spdlog (FetchContent で自動取得)、argparse (deps/ にバンドル)
- **用途**: `srtla_rec` (受信側) と `srtla_send` (送信側) を提供。サーバーでは `srtla_rec` を使用。

```bash
git clone --branch main --depth 1 https://github.com/irlserver/srtla.git
cd srtla && mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)
sudo install -m 0755 srtla_rec /usr/local/bin/srtla_rec
```

**備考:**
- spdlog は https://github.com/irlserver/spdlog.git (tag 1.9.2) から自動的に取得される
- argparse ヘッダーは `deps/argparse/include/` に配置されている (リポジトリにバンドル)
- srtla 自体にはシステムの SRT 依存は不要

**srtla_rec CLI オプション:**

| オプション | デフォルト | 説明 |
|--------|---------|-------------|
| `--srtla_port PORT` | 5000 | SRTLA リスナーポート (モバイルクライアントの接続先) |
| `--srt_hostname HOST` | 127.0.0.1 | 下流の SRT サーバーアドレス |
| `--srt_port PORT` | 4001 | 下流の SRT サーバーポート |
| `--verbose` | off | 詳細ログ出力 |
| `--debug` | off | デバッグログ出力 |

**一般的な使用方法:**
```bash
srtla_rec --srtla_port 5000 --srt_hostname 127.0.0.1 --srt_port 4002 --verbose
```

注意: srtla_rec は srt_server の `listen_publisher_srtla` ポート (4002) に転送する。通常の publisher ポートではない。

### 3. irlserver/irl-srt-server

- **ブランチ**: `main`
- **バージョン**: 3.1.0
- **ビルドシステム**: CMake 3.10+
- **言語**: C++17
- **依存**: libsrt (手順1で構築)、および git サブモジュール:
  - spdlog (lib/spdlog) - irlserver/spdlog branch 1.9.2
  - nlohmann/json (lib/json)
  - thread-pool (lib/thread-pool) - bshoshany/thread-pool
  - cpp-httplib (lib/cpp-httplib) - yhirose/cpp-httplib
  - CxxUrl (lib/CxxUrl) - chmike/CxxUrl
- **用途**: SRT Live Server - SRT ストリームを受信し、プレイヤーに配信する

```bash
git clone --branch main --depth 1 https://github.com/irlserver/irl-srt-server.git
cd irl-srt-server
git submodule update --init
mkdir build && cd build
cmake ../ -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)
sudo install -m 0755 bin/srt_server /usr/local/bin/srt_server
sudo install -m 0755 bin/srt_client /usr/local/bin/srt_client
```

**SRT のリンク方法**: CMakeLists は `target_link_libraries` で `srt` を直接リンクする。`find_package` は使用していないため、CMake は標準ライブラリパスから `libsrt` を検索する（SRT インストール後の `ldconfig` が重要）。

**生成されるバイナリ:**
- `srt_server` - メインの SRT Live Server
- `srt_client` - テストクライアント (push/play)
- `sls.conf` - デフォルト設定ファイル (build/bin/ にコピーされる)

## 設定

### sls.conf

配置先: `/etc/srt-live-server/sls.conf`

主要ポート割り当て:
- **4000**: プレイヤーポート (視聴者の接続先)
- **4001**: SRT 直接配信ポート (OBS/FFmpeg から直接接続)
- **4002**: SRTLA 配信ポート (srtla_rec からの転送先)
- **8181**: HTTP Stats API

ストリーム URL フォーマット: `srt://HOST:PORT?streamid=DOMAIN/APP/STREAM`
- 配信: `srt://host:4001?streamid=publish/live/stream1`
- 視聴: `srt://host:4000?streamid=play/live/stream1`
- SRTLA 配信: BELABOX エンコーダーは srtla_rec のポート 5000 に接続

### srtla_rec の設定

srtla_rec は CLI 引数のみで設定する (設定ファイルなし):
```
srtla_rec --srtla_port 5000 --srt_hostname 127.0.0.1 --srt_port 4002
```

接続クライアントIPの情報ファイルを `/tmp/srtla-group-[PORT]` に作成する。

## フェーズ 3: ffmpeg SRT→RTMP リレー

### ffmpeg のインストール

Ubuntu 24.04 には SRT および RTMP プロトコル対応の ffmpeg 6.1.1 が含まれている:

```bash
sudo apt-get install -y ffmpeg
# 確認: ffmpeg -protocols 2>/dev/null | grep -E 'srt|rtmp'
```

### リレー設定

リレーは systemd テンプレートユニット (`srt-relay@.service`) を使用し、複数プラットフォームへの同時配信に対応する。

**環境変数ファイル** (ストリームキー):
- `/etc/srt-live-server/relay-twitch.env` - Twitch RTMP URL + ストリームキー
- `/etc/srt-live-server/relay-youtube.env` - YouTube RTMP URL + ストリームキー
- パーミッション: `0640 root:srt`

**環境変数ファイルの主要変数:**
| 変数 | 説明 |
|----------|-------------|
| `SRT_INPUT` | SRT ソース URL (デフォルト: `srt://127.0.0.1:4000?streamid=play/live/feed1&mode=caller`) |
| `RTMP_URL` | RTMP 配信先 URL (ストリームキーなし) |
| `STREAM_KEY` | プラットフォームのストリームキー (シークレット) |

### 使用方法

```bash
# プラットフォームのストリームキーを編集
sudo nano /etc/srt-live-server/relay-twitch.env

# リレーの有効化・起動
sudo systemctl enable --now srt-relay@twitch

# YouTube へのリレー起動 (同時マルチストリーミング)
sudo systemctl enable --now srt-relay@youtube

# ステータス・ログ確認
sudo systemctl status srt-relay@twitch
journalctl -u srt-relay@twitch -f

# リレー停止
sudo systemctl stop srt-relay@twitch
```

### ffmpeg コマンド詳細

```
ffmpeg -nostdin -loglevel warning \
    -analyzeduration 1000000 -probesize 500000 \
    -i "srt://127.0.0.1:4000?streamid=play/live/feed1&mode=caller" \
    -c copy -f flv "rtmp://live-tyo.twitch.tv/app/<stream_key>"
```

- `-c copy`: 再エンコードなし (パススルー、CPU 負荷最小)
- `-f flv`: RTMP は FLV コンテナフォーマットを使用
- `-nostdin`: ffmpeg が stdin を読み取るのを防止 (デーモンモードで必須)
- `-analyzeduration 1000000 -probesize 500000`: 解析時間を短縮し起動を高速化

## データフロー

```
BELABOX エンコーダー
    |
    | (SRTLA プロトコル、複数モバイル回線)
    v
srtla_rec :5000
    |
    | (SRT, localhost)
    v
srt_server :4002 (listen_publisher_srtla)
    |
    | (SRT)
    v
プレイヤー :4000 (listen_player)
    |
    | (SRT, localhost, ffmpeg がプレイヤーとして読み取り)
    v
ffmpeg (srt-relay@twitch / srt-relay@youtube)
    |
    | (RTMP)
    v
Twitch / YouTube 等
```

## 自動ビルドスクリプト

`build-all.sh` で3つのビルドを順番に実行する (依存パッケージのインストール込み)。

```bash
sudo ./build-all.sh           # 全ビルド (apt 依存込み)
./build-all.sh --no-deps      # apt install をスキップ
```
