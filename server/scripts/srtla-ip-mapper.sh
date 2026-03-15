#!/usr/bin/env bash
#
# srtla-ip-mapper.sh - Capture SRTLA packets and build port -> source IP mapping
#
# Runs briefly with tcpdump to discover which source IPs are sending to the
# SRTLA port, performs reverse DNS lookups, and writes a mapping file that
# srt-stats-collector.sh can read without requiring CAP_NET_RAW.
#
# Output format (one line per port):
#   PORT IP HOSTNAME
#
# Environment variables:
#   SRTLA_PORT  - SRTLA listen port (default: 5000)
#   MAP_FILE    - Output mapping file (default: /tmp/srtla-ip-map)
#

set -euo pipefail

SRTLA_PORT="${SRTLA_PORT:-5000}"
MAP_FILE="${MAP_FILE:-/tmp/srtla-ip-map}"

# Capture a few inbound packets (timeout 2s, max 100 packets)
capture=$(timeout 2 tcpdump -i any -n -c 100 "udp dst port ${SRTLA_PORT}" 2>/dev/null) || true

if [[ -z "$capture" ]]; then
    exit 0
fi

# Extract unique source IP.port pairs
# tcpdump format: "IP 198.51.100.1.22877 > 192.168.0.10.5000: UDP"
pairs=$(echo "$capture" | grep -oP 'IP \K\d+\.\d+\.\d+\.\d+\.\d+(?= >)' | sort -u)

tmpfile="${MAP_FILE}.tmp"
> "$tmpfile"

while IFS= read -r pair; do
    [[ -z "$pair" ]] && continue
    port="${pair##*.}"
    ip="${pair%.*}"

    if [[ -z "$port" || -z "$ip" ]]; then
        continue
    fi

    # Reverse DNS lookup (timeout 2s)
    hostname=$(timeout 2 dig +short -x "$ip" 2>/dev/null | head -1 | sed 's/\.$//')
    if [[ -z "$hostname" ]]; then
        hostname="$ip"
    fi

    echo "${port} ${ip} ${hostname}" >> "$tmpfile"
done <<< "$pairs"

# Atomic replace
chmod 644 "$tmpfile"
mv -f "$tmpfile" "$MAP_FILE"
