#!/usr/bin/env bash
# /usr/local/bin/setup-source-routing.sh
# srtla_send 用の ips_file を生成し、ソースルーティングを設定する
#
# 対応インターフェース:
#   wlp4s0       - Wi-Fi / iPhone Wi-Fiテザリング (wifi テーブルでソースルーティング)
#   enp0s31f6    - 有線LAN (mobile1 テーブル)
#   enx*         - USB モバイルルーター / iOS USB テザリング等 (mobile1/mobile2 テーブル)
#                  同一IPの場合はダミーIF + SNAT で分離
#   usb0         - Android USB テザリング (mobile1/mobile2 テーブル)

set -euo pipefail

IPS_FILE="/etc/srtla-send/srtla_ips"
EXCLUDE_FILE="/etc/srtla-send/exclude_devs"  # 除外デバイス名リスト (1行1デバイス)
MOBILE_TABLES=(mobile1 mobile2)
DUMMY_IP_BASE="10.200"  # ダミーIP用プレフィクス

> "$IPS_FILE"

# 既存のソースルーティングルールをクリーンアップ (再実行時の重複防止)
for table in wifi mobile1 mobile2; do
    while ip rule del table "$table" 2>/dev/null; do :; done
done

mobile_idx=0   # 次に使う mobile テーブルのインデックス
dummy_idx=0    # ダミーIF の連番
declare -A used_ips  # IP重複検出用

# --- ヘルパー関数 ---

get_ip() {
    ip -4 addr show "$1" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1
}

get_gw() {
    ip route show dev "$1" 2>/dev/null | grep default | awk '{print $3}' | head -1
}

is_active() {
    ip link show "$1" 2>/dev/null | grep -qE 'state (UP|UNKNOWN)' &&
    ip -4 addr show "$1" 2>/dev/null | grep -q 'inet '
}

add_mobile_route() {
    local dev="$1" ip="$2" gw="$3"
    if (( mobile_idx >= ${#MOBILE_TABLES[@]} )); then
        echo "WARNING: No more mobile routing tables available, skipping $dev" >&2
        return 1
    fi
    local table="${MOBILE_TABLES[$mobile_idx]}"
    ip rule add from "$ip" table "$table" 2>/dev/null || true
    ip route replace default via "$gw" dev "$dev" table "$table"
    echo "$ip" >> "$IPS_FILE"
    echo "$dev: $ip via $gw (table $table)"
    (( mobile_idx++ )) || true
}

add_snat_route() {
    local dev="$1" real_ip="$2" gw="$3"
    if (( mobile_idx >= ${#MOBILE_TABLES[@]} )); then
        echo "WARNING: No more mobile routing tables available, skipping $dev" >&2
        return 1
    fi
    local table="${MOBILE_TABLES[$mobile_idx]}"
    local dummy_name="dummy-m${dummy_idx}"
    local virtual_ip="${DUMMY_IP_BASE}.${dummy_idx}.1"

    ip link add "$dummy_name" type dummy 2>/dev/null || true
    ip link set "$dummy_name" up
    ip addr replace "$virtual_ip/32" dev "$dummy_name"

    ip rule add from "$virtual_ip" table "$table" 2>/dev/null || true
    ip route replace default via "$gw" dev "$dev" table "$table"
    iptables -t nat -C POSTROUTING -s "$virtual_ip" -o "$dev" -j SNAT --to-source "$real_ip" 2>/dev/null ||
    iptables -t nat -A POSTROUTING -s "$virtual_ip" -o "$dev" -j SNAT --to-source "$real_ip"

    echo "$virtual_ip" >> "$IPS_FILE"
    echo "$dev: $virtual_ip -> SNAT $real_ip via $gw (table $table, dummy $dummy_name)"
    (( mobile_idx++ )) || true
    (( dummy_idx++ )) || true
}

# --- メイン処理 ---

# 1. Wi-Fi (wlp4s0) - wifi テーブルでソースルーティング
# テザリングデバイスがデフォルトルートを奪うため、WiFi にも明示的なソースルーティングが必要
if is_active wlp4s0; then
    WLP_IP=$(get_ip wlp4s0)
    WLP_GW=$(get_gw wlp4s0)
    if [[ -n "$WLP_GW" ]]; then
        ip route replace default via "$WLP_GW" dev wlp4s0 table wifi
        ip rule add from "$WLP_IP" table wifi 2>/dev/null || true
        echo "$WLP_IP" >> "$IPS_FILE"
        used_ips["$WLP_IP"]=wlp4s0
        echo "wlp4s0: $WLP_IP via $WLP_GW (table wifi)"
    fi
fi

# 2. 有線 (enp0s31f6)
if is_active enp0s31f6; then
    ETH_IP=$(get_ip enp0s31f6)
    ETH_GW=$(get_gw enp0s31f6)
    if [[ -n "$ETH_GW" ]]; then
        used_ips["$ETH_IP"]=enp0s31f6
        add_mobile_route enp0s31f6 "$ETH_IP" "$ETH_GW"
    fi
fi

# 3. iOS USB テザリング (enx*) + Android (usb*)
for dev in $(ip -o link show | grep -oP '(enx[0-9a-f]+|usb\d+)(?=:)' | sort); do
    # 除外リストに含まれるデバイスはスキップ
    if [[ -f "$EXCLUDE_FILE" ]] && grep -qx "$dev" "$EXCLUDE_FILE"; then
        echo "$dev: skipping (excluded)"
        continue
    fi

    if ! is_active "$dev"; then
        continue
    fi

    DEV_IP=$(get_ip "$dev")
    DEV_GW=$(get_gw "$dev")

    if [[ -z "$DEV_GW" ]]; then
        DEV_SUBNET=$(echo "$DEV_IP" | grep -oP '^\d+\.\d+\.\d+')
        DEV_GW="${DEV_SUBNET}.1"
    fi

    if [[ -z "${used_ips[$DEV_IP]+_}" ]]; then
        used_ips["$DEV_IP"]="$dev"
        add_mobile_route "$dev" "$DEV_IP" "$DEV_GW"
    else
        echo "$dev: IP $DEV_IP conflicts with ${used_ips[$DEV_IP]}, using SNAT"
        add_snat_route "$dev" "$DEV_IP" "$DEV_GW"
    fi
done

killall -HUP srtla_send 2>/dev/null || true
echo "Source routing configured. IPs in $IPS_FILE:"
cat "$IPS_FILE"
