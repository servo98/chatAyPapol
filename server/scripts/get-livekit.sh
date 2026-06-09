#!/usr/bin/env bash
# Descarga el binario de livekit-server (1 solo binario Go) a ./bin
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p bin
if [ -x bin/livekit-server ]; then echo "livekit-server ya está en bin/"; exit 0; fi
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m); case "$ARCH" in x86_64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; esac
VER=$(curl -fsSL https://api.github.com/repos/livekit/livekit/releases/latest | grep -oP '"tag_name":\s*"v\K[^"]+')
URL="https://github.com/livekit/livekit/releases/download/v${VER}/livekit_${VER}_${OS}_${ARCH}.tar.gz"
echo "Descargando livekit-server v${VER} (${OS}/${ARCH})..."
curl -fsSL "$URL" | tar -xz -C bin livekit-server
chmod +x bin/livekit-server
echo "Listo: bin/livekit-server"
