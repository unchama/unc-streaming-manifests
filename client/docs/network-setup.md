# ネットワーク設定 (ソースルーティング)

srtla_send が複数の NIC を使い分けるには、NIC ごとにソースルーティングを設定する必要がある。
また、srtla_send は `ips_file` で使用するソースIPを指定するため、ルーティング設定と合わせて ips_file を生成する。

## ルーティングテーブル定義

```bash
# /etc/iproute2/rt_tables に追加
echo "100 wifi" | sudo tee -a /etc/iproute2/rt_tables
echo "101 mobile1" | sudo tee -a /etc/iproute2/rt_tables
echo "102 mobile2" | sudo tee -a /etc/iproute2/rt_tables
```

## ソースルーティング設定スクリプト

ソースルーティング設定スクリプトは [`../setup-source-routing.sh`](../setup-source-routing.sh) にある。

このスクリプトは、各 NIC のソースルーティングを設定し、srtla_send 用の ips_file を生成する。

対応デバイス:
- `wlp4s0` — Wi-Fi / iPhone Wi-Fi テザリング (`wifi` テーブルでソースルーティング)
- `enp0s31f6` — 有線 LAN
- `enx*` — USB モバイルルーター / iOS USB テザリング (iPhone / iPad)
- `usb*` — Android USB テザリング

iOS USB テザリングは全デバイスが同じ `172.20.10.2/28` を割り当てるため、2台目以降はダミーインターフェース + SNAT で仮想IPを付与して分離する。

### スクリプトの配置

```bash
sudo install -m 0755 ../setup-source-routing.sh /usr/local/bin/setup-source-routing.sh
```

> **iOS USB テザリングの IP 重複について**: iPhone/iPad の USB テザリングはすべて `172.20.10.0/28` を使い、クライアントに `172.20.10.2` を割り当てる。2台以上接続した場合、スクリプトは2台目以降にダミーインターフェース (`dummy-m0` 等) と仮想IP (`10.200.0.1` 等) を割り当て、iptables SNAT で実IPに変換してルーティングする。

## デバイス除外 (exclude_devs)

GoPro 等のカメラが USB Ethernet (`enx*`) として認識される場合、ソースルーティングスクリプトがボンディング回線として誤検出する。
`/etc/srtla-send/exclude_devs` に除外するデバイス名を1行1つで記載すると、スクリプトがスキップする。

```bash
# /etc/srtla-send/exclude_devs
# GoPro HERO10 USB Ethernet
enx2474f75480b3
```

```bash
echo "enx2474f75480b3" | sudo tee /etc/srtla-send/exclude_devs
```

> デバイス名は MAC アドレスベースのため、異なる GoPro を接続すると名前が変わる。`ip link show` で確認して更新すること。

## NetworkManager との共存

Ubuntu Desktop の NetworkManager がルーティングを上書きする場合がある。
USBテザリングデバイスは unmanaged にするか、nmcli で個別設定する:

```bash
# 例: usb0 を NetworkManager の管理外にする
sudo nmcli device set usb0 managed no
```

## WiFi 単一回線運用時の注意

- ボンディングなしの単一回線運用は冗長性がないため、回線切断 = 配信停止
- 屋外配信ではテザリングに WiFi テザリングではなく **USB テザリング** を使用すること（WiFi テザリングは周囲の WiFi 環境に品質が左右される）
- 複数スマートフォンの USB テザリングで SRTLA ボンディングを構成するのが最も安定
- 可能であればモバイルテザリング（USB / WiFi）を追加して最低 2 回線のボンディングを推奨
- `srtla_ips` に 1 つしか IP がない場合、SRTLA のボンディング効果は得られない

## srtla_send の使い方

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

> **ips_file が空の場合**: `setup-source-routing.sh` が実行されても有効な NIC がなければ ips_file は空になる。空の場合は srtla-send の起動が失敗する（意図的な動作）。対処: NIC の接続を確認してから `sudo systemctl restart srtla-send` で再起動する。

### 実行例

```bash
srtla_send 9000 <unc-streaming-01のグローバルIP> 5000 /etc/srtla-send/srtla_ips
```
