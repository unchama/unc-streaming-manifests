#!/usr/bin/env bash
#
# setup-services.sh - Install systemd services for srtla_rec and srt_server
# Run on unc-streaming-01 after build-all.sh completes.
#
# Usage: sudo ./setup-services.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Setting up SRT streaming services ==="

# Create srt service user (no login, no home)
if ! id -u srt &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin srt
    echo "Created system user: srt"
fi

# Create required directories
mkdir -p /etc/srt-live-server
mkdir -p /var/log/srt-live-server
mkdir -p /run/srt-live-server
chown srt:srt /var/log/srt-live-server /run/srt-live-server

# Install config file
if [[ ! -f /etc/srt-live-server/sls.conf ]]; then
    cp "$SCRIPT_DIR/sls.conf.template" /etc/srt-live-server/sls.conf
    echo "Installed sls.conf to /etc/srt-live-server/sls.conf"
else
    echo "sls.conf already exists, skipping (check sls.conf.template for updates)"
fi

# Install systemd unit files
cp "$SCRIPT_DIR/systemd/srtla-rec.service" /etc/systemd/system/srtla-rec.service
cp "$SCRIPT_DIR/systemd/srt-live-server.service" /etc/systemd/system/srt-live-server.service
cp "$SCRIPT_DIR/systemd/srt-relay@.service" /etc/systemd/system/srt-relay@.service

# Install relay env template (do not overwrite existing platform configs)
for platform in twitch youtube; do
    if [[ ! -f "/etc/srt-live-server/relay-${platform}.env" ]]; then
        cp "$SCRIPT_DIR/relay.env.template" "/etc/srt-live-server/relay-${platform}.env"
        chown root:srt "/etc/srt-live-server/relay-${platform}.env"
        chmod 0640 "/etc/srt-live-server/relay-${platform}.env"
        echo "Installed relay-${platform}.env template (edit with actual stream key)"
    else
        echo "relay-${platform}.env already exists, skipping"
    fi
done

# Reload systemd and enable services
systemctl daemon-reload
systemctl enable srtla-rec.service
systemctl enable srt-live-server.service

echo ""
echo "=== Services installed and enabled ==="
echo ""
echo "Start services:"
echo "  sudo systemctl start srtla-rec"
echo "  sudo systemctl start srt-live-server"
echo ""
echo "SRT-to-RTMP relay (per platform):"
echo "  1. Edit stream key: sudo nano /etc/srt-live-server/relay-twitch.env"
echo "  2. Enable & start:  sudo systemctl enable --now srt-relay@twitch"
echo "  3. Check status:    sudo systemctl status srt-relay@twitch"
echo ""
echo "Check status:"
echo "  sudo systemctl status srtla-rec"
echo "  sudo systemctl status srt-live-server"
echo ""
echo "View logs:"
echo "  journalctl -u srtla-rec -f"
echo "  journalctl -u srt-live-server -f"
echo "  journalctl -u srt-relay@twitch -f"
echo ""
echo "Stats API:"
echo "  curl http://localhost:8181/stats"
echo ""
