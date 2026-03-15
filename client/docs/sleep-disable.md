# スリープ / サスペンド無効化

配信中にPCがスリープに入るとストリームが途切れるため、すべてのサスペンド経路を無効化する。

## GNOME 自動サスペンドの無効化

```bash
# AC電源時・バッテリー時ともに無効化
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'

# 確認
gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type
gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type
```

> **注意**: Ubuntu Desktop のデフォルトではバッテリー駆動時に **15分のアイドルでサスペンド** が有効。配信PCはバッテリー駆動で使うことがあるため、必ず無効化すること。

## systemd sleep ターゲットのマスク

GNOME 以外の経路（logind の IdleAction 等）からもサスペンドされないよう、systemd の sleep 関連ターゲットをマスクする。

```bash
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

## 蓋閉じ動作の無効化

`/etc/systemd/logind.conf` で蓋閉じ時の動作を `ignore` に設定する（配信PCは蓋を閉じたまま運用することがある）。

```ini
# /etc/systemd/logind.conf
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
```

```bash
sudo systemctl restart systemd-logind
```

> logind の再起動で GNOME セッションが切れる場合がある。設定変更後は OS を再起動するのが確実。
