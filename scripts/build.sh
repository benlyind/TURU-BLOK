#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/app"

echo "==> Building turublok (release)…"
swift build -c release

BIN="$ROOT/app/.build/release/turublok"
if [[ ! -x "$BIN" ]]; then
    echo "Build failed: binary not found at $BIN" >&2
    exit 1
fi

echo "==> Built: $BIN"
echo "==> Size: $(du -h "$BIN" | cut -f1)"
