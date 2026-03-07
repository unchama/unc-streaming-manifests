#!/usr/bin/env bash
#
# srt-stats-collector.sh - Poll SRT Stats API and SRTLA link stats,
#                          write overlay text for ffmpeg drawtext
#
# Environment variables:
#   SRT_API_KEY    - API key for stats endpoint authentication (optional)
#   POLL_INTERVAL  - Polling interval in seconds (default: 1)
#   OVERLAY_FILE   - Output file path (default: /tmp/srt-overlay.txt)
#

POLL_INTERVAL="${POLL_INTERVAL:-1}"
OVERLAY_FILE="${OVERLAY_FILE:-/tmp/srt-overlay.txt}"
STATS_URL="http://localhost:8181/stats"

CURL_OPTS=(-s --max-time 2)
if [[ -n "${SRT_API_KEY:-}" ]]; then
    CURL_OPTS+=(-H "Authorization: ${SRT_API_KEY}")
fi

cleanup() {
    rm -f "$OVERLAY_FILE" "${OVERLAY_FILE}.tmp"
    exit 0
}
trap cleanup SIGTERM SIGINT

write_overlay() {
    local text="$1"
    printf '%s' "$text" > "${OVERLAY_FILE}.tmp"
    mv -f "${OVERLAY_FILE}.tmp" "$OVERLAY_FILE"
}

# Parse the most recent SRTLA per-link stats from journalctl.
# srtla_rec logs lines like:
#   [::ffff:42259] [COMPARISON] ConnInfo: Weight=100%, Throttle=1.00, ErrPts=0 | Legacy: ...
# We extract port, Weight, and ErrPts from the ConnInfo section.
get_srtla_links() {
    local lines link_text=""
    # Get the last "Connection parameters adjusted" block
    lines=$(journalctl -u srtla-rec --no-pager -n 50 -o cat 2>/dev/null \
        | grep '\[COMPARISON\]' \
        | tail -10)

    if [[ -z "$lines" ]]; then
        echo ""
        return
    fi

    # Find the timestamp of the last COMPARISON line, then collect all lines with that timestamp
    local last_ts
    last_ts=$(echo "$lines" | tail -1 | grep -oP '^\[\K[0-9 :.T-]+' )

    local idx=0
    while IFS= read -r line; do
        local port weight errpts
        port=$(echo "$line" | grep -oP '::ffff:\K[0-9]+')
        weight=$(echo "$line" | grep -oP 'ConnInfo: Weight=\K[0-9]+')
        errpts=$(echo "$line" | grep -oP 'ErrPts=\K[0-9]+' | head -1)

        if [[ -n "$port" ]]; then
            idx=$((idx + 1))
            if [[ -n "$link_text" ]]; then
                link_text="${link_text} | "
            fi
            link_text="${link_text}Link${idx} :${port} Weight:${weight}% Err:${errpts}"
        fi
    done <<< "$(echo "$lines" | grep "$last_ts")"

    echo "$link_text"
}

while true; do
    response=$(curl "${CURL_OPTS[@]}" "$STATS_URL" 2>/dev/null) || response=""

    if [[ -z "$response" ]]; then
        write_overlay "Stats API unreachable"
        sleep "$POLL_INTERVAL"
        continue
    fi

    srt_line=$(printf '%s' "$response" | jq -r '
        .publishers // {} | to_entries | first // null |
        if . == null then
            "No Stream"
        else
            .value |
            "Bitrate: \(.bitrate // 0) kbps | RTT: \((.rtt // 0) * 10 | round / 10) ms | Loss: \(.pktRcvLoss // 0) | Drop: \(.pktRcvDrop // 0) | BW: \((.mbpsBandwidth // 0) * 10 | round / 10) Mbps"
        end
    ' 2>/dev/null) || srt_line="Stats parse error"

    srtla_line=$(get_srtla_links)

    if [[ -n "$srtla_line" ]]; then
        overlay="${srt_line}
${srtla_line}"
    else
        overlay="$srt_line"
    fi

    # Remove '%' for ffmpeg drawtext (interprets % as format specifier)
    overlay="${overlay//%/}"
    write_overlay "$overlay"

    sleep "$POLL_INTERVAL"
done
