# Stats API (ストリーム状態確認)

unc-streaming-01 の srt-live-server は HTTP API を提供しており、配信ストリームの状態を確認できる。

## エンドポイント

```
GET http://unc-streaming-01.seichi.internal:8181/stats
```

## 認証

`Authorization` ヘッダーに API キーを指定する。API キーは `/etc/srt-live-server/sls.conf` の `api_keys` ディレクティブで設定する。

```nginx
# /etc/srt-live-server/sls.conf (srt {} ブロック内)
api_keys <your-api-key>;

# 複数キーはカンマ区切り
# api_keys key1,key2,key3;
```

設定変更後は `sudo systemctl restart srt-live-server` で反映。

## アクセス方法

```bash
# curl
curl -H 'Authorization: <your-api-key>' http://unc-streaming-01.seichi.internal:8181/stats

# ブラウザから確認する場合は ModHeader 等の拡張機能で Authorization ヘッダーを付与するか、
# DevTools コンソールから:
# fetch('/stats', { headers: { 'Authorization': '<your-api-key>' } }).then(r => r.json()).then(console.log)
```

## レスポンス例

```json
{
  "publishers": {
    "publish/live/feed1": {
      "bitrate": 4962,
      "bytesRcvDrop": 0,
      "bytesRcvLoss": 0,
      "latency": 200,
      "mbpsBandwidth": 542.556,
      "mbpsRecvRate": 4.546,
      "msRcvBuf": 182,
      "pktRcvDrop": 0,
      "pktRcvLoss": 0,
      "rtt": 12.702,
      "uptime": 13
    }
  },
  "status": "ok"
}
```

| フィールド | 説明 |
|---|---|
| `bitrate` | 受信ビットレート (kbps) |
| `latency` | 設定レイテンシ (ms) |
| `rtt` | ラウンドトリップタイム (ms) |
| `pktRcvLoss` | 受信パケットロス数 |
| `pktRcvDrop` | 受信パケットドロップ数 |
| `uptime` | ストリーム継続時間 (秒) |
| `mbpsRecvRate` | 受信レート (Mbps) |
| `mbpsBandwidth` | 推定帯域幅 (Mbps) |
| `msRcvBuf` | 受信バッファ (ms) |
