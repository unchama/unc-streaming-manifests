#!/usr/bin/env bash
# /etc/NetworkManager/dispatcher.d/90-srtla-routing.sh
# NIC の UP/DOWN 時にソースルーティングを再設定し、srtla_send に反映する
#
# NetworkManager dispatcher はインターフェースイベント発生時に呼ばれる:
#   $1 = インターフェース名
#   $2 = アクション (up, down, connectivity-change, etc.)
#
# 対象: USB テザリング (enx*, usb*) と Wi-Fi (wlp4s0) の up/down のみ

INTERFACE="$1"
ACTION="$2"

# 対象インターフェースか判定
case "$INTERFACE" in
    enx*|usb*|wlp4s0|enp0s31f6) ;;
    *) exit 0 ;;
esac

# up/down のみ処理
case "$ACTION" in
    up|down) ;;
    *) exit 0 ;;
esac

logger -t srtla-routing "Interface $INTERFACE $ACTION, reconfiguring source routing"
/usr/local/bin/setup-source-routing.sh 2>&1 | logger -t srtla-routing
