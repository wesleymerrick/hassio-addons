#!/usr/bin/env bash
# Build frontend (selfhosted mode) + donetick binary and place the binary in the addon folder.
# Run this directly or via scripts/deploy.sh.
set -euo pipefail

# Go may have been installed to /usr/local/go after the shell was opened
export PATH=$PATH:/usr/local/go/bin

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDON_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_ROOT="$(cd "$ADDON_ROOT/.." && pwd)"
FRONTEND_DIR="$WORKSPACE_ROOT/frontend"
DONETICK_DIR="$WORKSPACE_ROOT/donetick"
ADDON_DIR="$ADDON_ROOT/donetick"

echo "==> [1/3] Building frontend (selfhosted mode)..."
cd "$FRONTEND_DIR"
npm install --silent
npx vite build --mode selfhosted

echo "==> [2/3] Copying frontend dist into donetick Go package..."
rm -rf "$DONETICK_DIR/frontend/dist"
cp -r "$FRONTEND_DIR/dist" "$DONETICK_DIR/frontend/dist"

echo "==> Copying donetick config into addon folder..."
cp -r "$DONETICK_DIR/config" "$ADDON_DIR/config"

echo "==> [3/3] Cross-compiling donetick binary (linux/amd64)..."
cd "$DONETICK_DIR"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-s -w -X donetick.com/core/config.Version=dev -X donetick.com/core/config.Commit=local" \
    -buildvcs=false \
    -o "$ADDON_DIR/donetick" .

echo "==> Binary written to $ADDON_DIR/donetick"
