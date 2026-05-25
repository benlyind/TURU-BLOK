#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Default: pakai installed binary biar Accessibility permission match dengan production.
# Fallback ke build binary kalau belum di-install.
BIN="$HOME/.local/bin/turublok"
if [[ ! -x "$BIN" ]]; then
    BIN="$ROOT/app/.build/release/turublok"
    echo "⚠️  Pakai build binary ($BIN) — install dulu biar Accessibility match dengan production." >&2
fi
DURATION="${1:-30}"

if [[ ! -x "$BIN" ]]; then
    echo "Binary belum di-build. Jalankan dulu: scripts/build.sh" >&2
    exit 1
fi

echo "==> Test mode: lock selama ${DURATION} detik."
echo "==> Setelah ${DURATION} detik, layar otomatis unlock & app exit."
echo "==> Kalau Accessibility permission belum dikasih, keyboard shortcut TIDAK akan diblokir."
echo "==> Tekan Cmd+Q ga akan menutup app, tapi kalau panik banget: power button 5 detik."
echo ""
echo "Lanjut dalam 3 detik..."
sleep 3

"$BIN" --test "$DURATION"
