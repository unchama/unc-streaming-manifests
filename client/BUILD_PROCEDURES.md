# srtla_send ビルド手順

## ビルド

```bash
sudo mkdir -p /opt/irl-srt && cd /opt/irl-srt

git clone --branch main --depth 1 https://github.com/irlserver/srtla.git
cd srtla
git submodule update --init
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)

sudo install -m 0755 srtla_send /usr/local/bin/srtla_send
```

## 付録: srtla_send が Release ビルドで異常動作する (assert バグ)

上流の srtla リポジトリの `sender.cpp` には、`assert()` の内部で副作用のある関数呼び出し (`get_seconds()`, `get_ms()`) を行っている箇所がある。`-DCMAKE_BUILD_TYPE=Release` でビルドすると `-DNDEBUG` が定義され、`assert()` がマクロ展開で消えるため、時刻変数が未初期化のまま使用される。

**症状**: srtla_send が即座にクラッシュする、または接続のハウスキーピングが正常に動作しない。

**対処法**: `sender.cpp` の該当箇所を修正し、関数呼び出しを assert の外に出す:

```cpp
// 修正前 (NG: Release ビルドで消える)
assert(get_seconds(&t) == 0);

// 修正後 (OK)
{ int _ret = get_seconds(&t); assert(_ret == 0); (void)_ret; }
```

該当箇所は L181 (`get_seconds`) と L602 (`get_ms`) の2箇所。修正後は再ビルドして `srtla_send` を再配置する。

> **注意**: `assert()` 内に副作用のあるコード (関数呼び出し、代入など) を入れてはならない。Release ビルド (`-DNDEBUG`) で assert が無効化されると副作用ごと消える。
