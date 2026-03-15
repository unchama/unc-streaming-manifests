# トラブルシューティング

## VAAPI が使えない

```bash
# ドライバの確認
sudo apt install intel-media-va-driver-non-free
# 権限確認
ls -la /dev/dri/renderD128
# video グループに追加
sudo usermod -aG video $USER
```

## srtla_send が NIC にバインドできない

- ips_file にNICのIPが正しく記載されているか確認
- ソースルーティングが正しく設定されているか確認
- `ip route get <srtla_rec IP> from <NIC IP>` で経路確認
- NetworkManager がルーティングを上書きしていないか確認

## OBS / FFmpeg で SRT 接続エラー

- srtla_send が起動しているか確認
- SRT URL の `mode=caller` を確認
- ポート番号が srtla_send の listen_port と一致しているか確認

## 配信中にPCがスリープに入る

- GNOME 自動サスペンドが有効になっていないか確認: `gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type`
- systemd sleep ターゲットがマスクされているか確認: `systemctl status sleep.target`
- logind の蓋閉じ設定を確認: `grep HandleLidSwitch /etc/systemd/logind.conf`
- 詳細は [スリープ / サスペンド無効化](sleep-disable.md) を参照

## GoPro がウェブカメラモードにならない

- `lsusb | grep GoPro` で USB デバイスとして認識されているか確認
- USB Ethernet インターフェースが作成されているか確認: `ip link show | grep enx`
- GoPro API にアクセスできるか確認: `wget -qO- http://172.23.114.51:8080/gopro/webcam/status`
  - 接続できない場合、GoPro の IP が異なる可能性がある。`ip route` でゲートウェイの IP を確認し、末尾を `.51` に変えて試す
- ウェブカメラモード開始後に `/dev/video` として出ない場合は正常。Linux ではUDP ストリーム (`udp://172.23.114.51:8554`) で受信する

## GoPro が srtla のボンディング回線として誤検出される

GoPro の USB Ethernet (`enx*`) がソースルーティングスクリプトに拾われている。`/etc/srtla-send/exclude_devs` にデバイス名を追加して `systemctl restart srtla-send` する。

```bash
ip link show | grep enx  # GoPro のインターフェース名を確認
echo "enx2474f75480b3" | sudo tee -a /etc/srtla-send/exclude_devs
sudo systemctl restart srtla-send
```

## Cam Link 4K のデバイスパスが変わった

再起動や USB の抜き差しで `/dev/videoX` の番号が変わることがある。udev ルールで `/dev/camlink` シンボリックリンクを作成していれば影響を受けない。

```bash
# シンボリックリンク確認
ls -la /dev/camlink
# udev ルールが適用されているか確認
udevadm info /dev/camlink
# ルールが未適用の場合
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=video4linux
```

## Cam Link 4K が認識されない

```bash
# デバイス一覧
v4l2-ctl --list-devices
# 対応フォーマット確認
v4l2-ctl -d /dev/camlink --list-formats-ext
# カーネルログ確認
dmesg | grep -i cam
```

## srtla-send が再起動ループする

**症状**: journalctl に「restart counter」が高速に増加、srtla_send が数秒で終了を繰り返す

**原因**: ネットワーク未接続時に ips_file が空になる

**対処**:

1. `cat /etc/srtla-send/srtla_ips` でファイル内容確認
2. 空の場合、WiFi / 有線 / テザリングのいずれかを接続
3. `ip -4 addr show` で IP アドレスが割り当てられていることを確認
4. `sudo systemctl restart srtla-send` で再起動

**注意**: 短時間に5回以上再起動が失敗すると、systemd の StartLimit によりサービスが `failed (start-limit-hit)` 状態でロックされる。この場合は以下で復旧する:

```bash
sudo systemctl reset-failed srtla-send
sudo systemctl start srtla-send
```

## V4L2 キャプチャデバイスが途中で喪失する

**症状**: `ioctl(VIDIOC_DQBUF): No such device` や `ALSA read error: No such device`

**原因**: USB キャプチャデバイス（Cam Link 4K 等）の物理的な接続断

**対処**:

1. USB ケーブルの接続を確認、別ポートに差し替え
2. `ls /dev/video*` でデバイスが復活しているか確認
3. `sudo systemctl restart srt-capture` で再起動
4. 頻発する場合は USB ハブの電力不足やケーブル劣化を疑う
