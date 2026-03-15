# Tailscale (リモートアクセス)

配信PC へのリモート SSH アクセス用に Tailscale を導入する。

## インストール

```bash
wget -qO- https://tailscale.com/install.sh | sudo sh
sudo tailscale up --accept-routes=false
```

表示される認証 URL をブラウザで開いてログインし、管理画面でマシンを承認する。

## SSH 接続

```bash
ssh unchama@<tailscale-ip>
# または MagicDNS が有効なら
ssh unchama@unchama-thinkpad-t470
```

Tailscale IP は `tailscale ip -4` で確認できる。

## ソースルーティングとの共存

Tailscale は `fwmark` ベースの ip rule（priority 5210-5270）を使用し、srtla のソースIPベースのルーティング（priority 32765）とは干渉しない。以下を守れば安全に共存できる:

- `--exit-node` は使わない（全トラフィックが Tailscale 経由になり配信が途切れる）
- `--accept-routes=false` のまま運用する（デフォルト）
- インストール後に `ip rule list` でソースルーティングが残っていることを確認する
