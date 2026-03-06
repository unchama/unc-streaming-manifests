# IRL SRT Stack Build Procedures

## Overview

3 repositories to build in order:

1. **irlserver/srt** (belabox branch) - BELABOX fork of SRT library
2. **irlserver/srtla** (main branch) - SRTLA proxy (srtla_rec)
3. **irlserver/irl-srt-server** (main branch) - SRT Live Server

## System Dependencies (apt)

```
build-essential cmake git pkg-config libssl-dev tclsh
```

## Build Order and Details

### 1. irlserver/srt (BELABOX fork)

- **Branch**: `belabox` (not master/main)
- **Version**: v1.5.4 (latest release: v1.5.4-irl2)
- **Build system**: CMake 2.8.12+
- **Language**: C/C++
- **Key dependency**: OpenSSL (libssl-dev)
- **Purpose**: Provides libsrt shared/static library. Required by both srtla and irl-srt-server.

```bash
git clone --branch belabox --depth 1 https://github.com/irlserver/srt.git
cd srt && mkdir build && cd build
cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_ENCRYPTION=ON -DENABLE_APPS=OFF -DENABLE_SHARED=ON -DENABLE_STATIC=ON
make -j$(nproc)
sudo make install
sudo ldconfig
```

**Important CMake options:**
- `ENABLE_ENCRYPTION=ON` - AES encryption (needs OpenSSL)
- `ENABLE_APPS=OFF` - Skip sample apps (not needed)
- `ENABLE_BONDING=OFF` - Default off, not needed for server
- `ENABLE_STDCXX_SYNC` - Platform-dependent default, usually fine

**Result**: Installs `libsrt.so`, `libsrt.a`, headers, and pkg-config file to `/usr/local`.

### 2. irlserver/srtla

- **Branch**: `main`
- **Version**: 1.0.0
- **Build system**: CMake 3.16+
- **Language**: C/C++17
- **Dependencies**: spdlog (auto-fetched via FetchContent), argparse (bundled in deps/)
- **Purpose**: Provides `srtla_rec` (receiver) and `srtla_send` (sender). We use `srtla_rec`.

```bash
git clone --branch main --depth 1 https://github.com/irlserver/srtla.git
cd srtla && mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)
sudo install -m 0755 srtla_rec /usr/local/bin/srtla_rec
```

**Notes:**
- spdlog is fetched automatically from https://github.com/irlserver/spdlog.git (tag 1.9.2)
- argparse headers are expected at `deps/argparse/include/` (bundled in repo)
- No system SRT dependency needed for srtla itself

**srtla_rec CLI options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--srtla_port PORT` | 5000 | SRTLA listener port (mobile clients connect here) |
| `--srt_hostname HOST` | 127.0.0.1 | Downstream SRT server address |
| `--srt_port PORT` | 4001 | Downstream SRT server port |
| `--verbose` | off | Verbose logging |
| `--debug` | off | Debug logging |

**Typical usage:**
```bash
srtla_rec --srtla_port 5000 --srt_hostname 127.0.0.1 --srt_port 4002 --verbose
```

Note: srtla_rec forwards to the `listen_publisher_srtla` port (4002) of srt_server, NOT the regular publisher port.

### 3. irlserver/irl-srt-server

- **Branch**: `main`
- **Version**: 3.1.0
- **Build system**: CMake 3.10+
- **Language**: C++17
- **Dependencies**: libsrt (from step 1), plus git submodules:
  - spdlog (lib/spdlog) - from irlserver/spdlog branch 1.9.2
  - nlohmann/json (lib/json)
  - thread-pool (lib/thread-pool) - bshoshany/thread-pool
  - cpp-httplib (lib/cpp-httplib) - yhirose/cpp-httplib
  - CxxUrl (lib/CxxUrl) - chmike/CxxUrl
- **Purpose**: SRT Live Server - receives SRT streams, serves them to players

```bash
git clone --branch main --depth 1 https://github.com/irlserver/irl-srt-server.git
cd irl-srt-server
git submodule update --init
mkdir build && cd build
cmake ../ -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)
sudo install -m 0755 bin/srt_server /usr/local/bin/srt_server
sudo install -m 0755 bin/srt_client /usr/local/bin/srt_client
```

**How SRT is linked**: The CMakeLists links `srt` directly via `target_link_libraries`. No `find_package` is used - CMake finds `libsrt` via standard library paths (hence `ldconfig` after installing SRT is critical).

**Binaries produced:**
- `srt_server` - Main SRT live server
- `srt_client` - Test client (push/play)
- `sls.conf` - Default config (copied to build/bin/)

## Configuration

### sls.conf

Location: `/etc/srt-live-server/sls.conf`

Key port assignments:
- **4000**: Player port (viewers connect here)
- **4001**: Direct SRT publisher port (OBS/FFmpeg direct)
- **4002**: SRTLA publisher port (srtla_rec forwards here)
- **8181**: HTTP stats API

Stream URL format: `srt://HOST:PORT?streamid=DOMAIN/APP/STREAM`
- Publish: `srt://host:4001?streamid=publish/live/stream1`
- Play: `srt://host:4000?streamid=play/live/stream1`
- SRTLA publish: BELABOX encoder connects to srtla_rec on port 5000

### srtla_rec configuration

srtla_rec is configured via CLI args only (no config file):
```
srtla_rec --srtla_port 5000 --srt_hostname 127.0.0.1 --srt_port 4002
```

Creates info files at `/tmp/srtla-group-[PORT]` with connected client IPs.

## Phase 3: ffmpeg SRT-to-RTMP Relay

### ffmpeg Installation

Ubuntu 24.04 ships ffmpeg 6.1.1 with SRT and RTMP protocol support:

```bash
sudo apt-get install -y ffmpeg
# Verify: ffmpeg -protocols 2>/dev/null | grep -E 'srt|rtmp'
```

### Relay Configuration

The relay uses a systemd template unit (`srt-relay@.service`) to support multiple platforms simultaneously.

**Environment files** (stream keys):
- `/etc/srt-live-server/relay-twitch.env` - Twitch RTMP URL + stream key
- `/etc/srt-live-server/relay-youtube.env` - YouTube RTMP URL + stream key
- Permissions: `0640 root:srt`

**Key variables in env files:**
| Variable | Description |
|----------|-------------|
| `SRT_INPUT` | SRT source URL (default: `srt://127.0.0.1:4000?streamid=play/live/feed1&mode=caller`) |
| `RTMP_URL` | RTMP ingest URL (without stream key) |
| `STREAM_KEY` | Platform stream key (secret) |

### Usage

```bash
# Edit stream key for a platform
sudo nano /etc/srt-live-server/relay-twitch.env

# Enable and start relay for a platform
sudo systemctl enable --now srt-relay@twitch

# Start relay for YouTube (simultaneous multistream)
sudo systemctl enable --now srt-relay@youtube

# Check status / logs
sudo systemctl status srt-relay@twitch
journalctl -u srt-relay@twitch -f

# Stop relay
sudo systemctl stop srt-relay@twitch
```

### ffmpeg Command Details

```
ffmpeg -nostdin -loglevel warning \
    -analyzeduration 1000000 -probesize 500000 \
    -i "srt://127.0.0.1:4000?streamid=play/live/feed1&mode=caller" \
    -c copy -f flv "rtmp://live-tyo.twitch.tv/app/<stream_key>"
```

- `-c copy`: No re-encoding (passthrough, minimal CPU)
- `-f flv`: RTMP uses FLV container format
- `-nostdin`: Prevents ffmpeg from reading stdin (required for daemon mode)
- `-analyzeduration 1000000 -probesize 500000`: Reduced probe time for faster startup

## Data Flow

```
BELABOX Encoder
    |
    | (SRTLA protocol, multiple cellular links)
    v
srtla_rec :5000
    |
    | (SRT, localhost)
    v
srt_server :4002 (listen_publisher_srtla)
    |
    | (SRT)
    v
Players :4000 (listen_player)
    |
    | (SRT, localhost, ffmpeg reads as player)
    v
ffmpeg (srt-relay@twitch / srt-relay@youtube)
    |
    | (RTMP)
    v
Twitch / YouTube / etc.
```

## Automated Build Script

See `build-all.sh` - runs all three builds in sequence with dependency installation.

```bash
sudo ./build-all.sh           # Full build with apt deps
./build-all.sh --no-deps      # Skip apt install
```
