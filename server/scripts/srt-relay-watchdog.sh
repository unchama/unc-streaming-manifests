#!/usr/bin/env bash
# srt-relay-watchdog.sh
# srt-relay@* の RTMP 出力が停滞していたら再起動する
#
# 判定ロジック:
#   1. publisher が存在しなければ何もしない (入力がないので再起動しても無意味)
#   2. relay の ffmpeg PID から /proc/<pid>/io の write_bytes を 2回サンプリング
#   3. 増加していなければ出力が停滞していると判断し restart

set -euo pipefail

STATS_URL="http://localhost:8181/stats"
API_KEY_FILE="/etc/srt-live-server/stats-collector.env"
SAMPLE_INTERVAL=5  # 秒

# API キー読み込み (stats-collector.env があればそこから、なければ引数から)
if [[ -f "$API_KEY_FILE" ]] && grep -q '^SRT_API_KEY=' "$API_KEY_FILE"; then
    API_KEY=$(grep '^SRT_API_KEY=' "$API_KEY_FILE" | cut -d= -f2-)
elif [[ -n "${1:-}" ]]; then
    API_KEY="$1"
else
    echo "ERROR: No API key found" >&2
    exit 1
fi

# publisher が存在するか確認
stats=$(curl -sf -H "Authorization: $API_KEY" "$STATS_URL" 2>/dev/null || echo '{}')
publisher_count=$(echo "$stats" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('publishers',{})))" 2>/dev/null || echo 0)

if [[ "$publisher_count" -eq 0 ]]; then
    echo "$(date -Iseconds) No active publishers, skipping check"
    exit 0
fi

# 各 relay インスタンスをチェック
restarted=0
for unit in $(systemctl list-units --type=service --state=running --plain --no-legend 'srt-relay@*' 'srt-relay-debug@*' | awk '{print $1}'); do
    pid=$(systemctl show -p MainPID --value "$unit")
    if [[ -z "$pid" || "$pid" == "0" ]]; then
        continue
    fi

    io_file="/proc/$pid/io"
    if [[ ! -f "$io_file" ]]; then
        continue
    fi

    bytes1=$(awk '/^write_bytes:/{print $2}' "$io_file")
    sleep "$SAMPLE_INTERVAL"
    bytes2=$(awk '/^write_bytes:/{print $2}' "$io_file" 2>/dev/null || echo "$bytes1")

    if [[ "$bytes1" == "$bytes2" ]]; then
        echo "$(date -Iseconds) $unit: output stalled (write_bytes=$bytes1), restarting"
        systemctl restart "$unit"
        (( restarted++ )) || true
    else
        delta=$(( bytes2 - bytes1 ))
        echo "$(date -Iseconds) $unit: healthy (wrote ${delta} bytes in ${SAMPLE_INTERVAL}s)"
    fi
done

if [[ "$restarted" -gt 0 ]]; then
    echo "$(date -Iseconds) Restarted $restarted relay(s)"
fi
