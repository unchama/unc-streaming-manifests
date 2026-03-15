#!/usr/bin/env bash
#
# build-all.sh - Build irlserver SRT stack (srt + srtla + irl-srt-server)
# Target: Ubuntu 22.04+ / Debian 12+ (amd64)
#
# Usage:
#   sudo ./build-all.sh          # Install deps + build all
#   ./build-all.sh --no-deps     # Skip apt install (if deps already installed)
#
set -euo pipefail

########################################################################
# Configuration
########################################################################
BUILD_DIR="${BUILD_DIR:-/opt/irl-srt}"
SRT_BRANCH="belabox"
SRTLA_BRANCH="main"
SLS_BRANCH="main"
INSTALL_PREFIX="/usr/local"
JOBS="$(nproc)"

SKIP_DEPS=false
if [[ "${1:-}" == "--no-deps" ]]; then
    SKIP_DEPS=true
fi

########################################################################
# 0. Install system dependencies
########################################################################
install_deps() {
    echo "=== Installing system dependencies ==="
    apt-get update
    apt-get install -y \
        build-essential \
        cmake \
        git \
        pkg-config \
        libssl-dev \
        tclsh
    echo "=== Dependencies installed ==="
}

if [[ "$SKIP_DEPS" == false ]]; then
    install_deps
fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

########################################################################
# 1. Build irlserver/srt (BELABOX fork)
########################################################################
build_srt() {
    echo ""
    echo "================================================================"
    echo "  Step 1/3: Building irlserver/srt (BELABOX fork, branch: $SRT_BRANCH)"
    echo "================================================================"

    if [[ ! -d srt ]]; then
        git clone --branch "$SRT_BRANCH" --depth 1 \
            https://github.com/irlserver/srt.git
    fi

    cd srt
    mkdir -p build && cd build

    cmake .. \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DENABLE_ENCRYPTION=ON \
        -DENABLE_APPS=OFF \
        -DENABLE_SHARED=ON \
        -DENABLE_STATIC=ON

    make -j"$JOBS"
    make install

    # Update ldconfig so libsrt can be found
    ldconfig

    echo "--- SRT library installed to $INSTALL_PREFIX ---"
    cd "$BUILD_DIR"
}

########################################################################
# 2. Build irlserver/srtla
########################################################################
build_srtla() {
    echo ""
    echo "================================================================"
    echo "  Step 2/3: Building irlserver/srtla (branch: $SRTLA_BRANCH)"
    echo "================================================================"

    if [[ ! -d srtla ]]; then
        git clone --branch "$SRTLA_BRANCH" --depth 1 \
            https://github.com/irlserver/srtla.git
    fi

    cd srtla
    git submodule update --init
    mkdir -p build && cd build

    cmake .. \
        -DCMAKE_BUILD_TYPE=Release

    make -j"$JOBS"

    # Install srtla_rec binary
    install -m 0755 srtla_rec "$INSTALL_PREFIX/bin/srtla_rec"
    echo "--- srtla_rec installed to $INSTALL_PREFIX/bin/srtla_rec ---"

    cd "$BUILD_DIR"
}

########################################################################
# 3. Build irlserver/irl-srt-server
########################################################################
build_sls() {
    echo ""
    echo "================================================================"
    echo "  Step 3/3: Building irlserver/irl-srt-server (branch: $SLS_BRANCH)"
    echo "================================================================"

    if [[ ! -d irl-srt-server ]]; then
        git clone --branch "$SLS_BRANCH" --depth 1 \
            https://github.com/irlserver/irl-srt-server.git
    fi

    cd irl-srt-server

    # Initialize submodules (spdlog, json, thread-pool, cpp-httplib, CxxUrl)
    git submodule update --init

    mkdir -p build && cd build

    cmake ../ \
        -DCMAKE_BUILD_TYPE=Release

    make -j"$JOBS"

    # Install binaries
    install -m 0755 bin/srt_server "$INSTALL_PREFIX/bin/srt_server"
    install -m 0755 bin/srt_client "$INSTALL_PREFIX/bin/srt_client"

    # Install default config
    mkdir -p /etc/srt-live-server
    if [[ ! -f /etc/srt-live-server/sls.conf ]]; then
        cp bin/sls.conf /etc/srt-live-server/sls.conf
        echo "--- Default sls.conf installed to /etc/srt-live-server/sls.conf ---"
    else
        echo "--- /etc/srt-live-server/sls.conf already exists, skipping ---"
    fi

    echo "--- srt_server installed to $INSTALL_PREFIX/bin/srt_server ---"
    cd "$BUILD_DIR"
}

########################################################################
# Main
########################################################################
echo "============================================="
echo "  IRL SRT Stack Builder"
echo "  Build directory: $BUILD_DIR"
echo "  Install prefix:  $INSTALL_PREFIX"
echo "  Parallel jobs:   $JOBS"
echo "============================================="

build_srt
build_srtla
build_sls

echo ""
echo "============================================="
echo "  Build complete!"
echo "============================================="
echo ""
echo "Installed binaries:"
echo "  - srtla_rec:   $INSTALL_PREFIX/bin/srtla_rec"
echo "  - srt_server:  $INSTALL_PREFIX/bin/srt_server"
echo "  - srt_client:  $INSTALL_PREFIX/bin/srt_client"
echo ""
echo "Config file:"
echo "  - /etc/srt-live-server/sls.conf"
echo ""
echo "Verify:"
echo "  srtla_rec --help"
echo "  srt_server -h"
echo ""
