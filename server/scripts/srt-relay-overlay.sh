#!/usr/bin/env bash
# srt-relay-overlay.sh - 本番リレーのデバッグオーバーレイ ON/OFF 切り替え
#
# Usage:
#   srt-relay-overlay.sh on  [instance]   # オーバーレイ有効化 (default: youtube)
#   srt-relay-overlay.sh off [instance]   # オーバーレイ無効化
#   srt-relay-overlay.sh status [instance] # 現在の状態確認
#
# ON にすると映像が x264 再エンコードになるため CPU 負荷が増加する (ultrafast で 1-2 コア程度)

set -euo pipefail

ACTION="${1:-status}"
INSTANCE="${2:-youtube}"
UNIT="srt-relay@${INSTANCE}.service"
OVERRIDE_DIR="/etc/systemd/system/${UNIT}.d"
OVERRIDE_FILE="${OVERRIDE_DIR}/overlay.conf"

case "$ACTION" in
    on)
        # srt-stats-collector が動いていなければ起動
        systemctl is-active --quiet srt-stats-collector || systemctl start srt-stats-collector

        mkdir -p "$OVERRIDE_DIR"
        cat > "$OVERRIDE_FILE" << 'CONF'
[Service]
PrivateTmp=no
ExecStart=
ExecStart=/usr/bin/ffmpeg \
    -nostdin \
    -loglevel warning \
    -analyzeduration 1000000 \
    -probesize 500000 \
    -i ${SRT_INPUT} \
    -vf "drawtext=textfile=/tmp/srt-overlay.txt:reload=1:fontsize=20:fontcolor=white:borderw=2:bordercolor=black:x=10:y=10" \
    -c:v libx264 -preset ultrafast -tune zerolatency -b:v 4500k -g 120 \
    -af aresample=async=1:first_pts=0 \
    -c:a aac -b:a 128k \
    -f flv \
    "${RTMP_URL}/${STREAM_KEY}"
CONF
        systemctl daemon-reload
        systemctl restart "$UNIT"
        echo "Overlay ON for $UNIT (x264 re-encode + drawtext)"
        ;;
    off)
        if [[ -f "$OVERRIDE_FILE" ]]; then
            rm "$OVERRIDE_FILE"
            rmdir "$OVERRIDE_DIR" 2>/dev/null || true
            systemctl daemon-reload
            systemctl restart "$UNIT"
            echo "Overlay OFF for $UNIT (video passthrough)"
        else
            echo "Overlay is already OFF for $UNIT"
        fi
        ;;
    status)
        if [[ -f "$OVERRIDE_FILE" ]]; then
            echo "Overlay: ON (x264 re-encode + drawtext)"
        else
            echo "Overlay: OFF (video passthrough)"
        fi
        systemctl is-active "$UNIT" && echo "Service: running" || echo "Service: not running"
        ;;
    *)
        echo "Usage: $0 {on|off|status} [instance]" >&2
        exit 1
        ;;
esac
