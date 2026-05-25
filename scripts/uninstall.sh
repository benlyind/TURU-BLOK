#!/usr/bin/env bash
set -euo pipefail

LOCK_PLIST="$HOME/Library/LaunchAgents/com.turublok.lock.plist"
EYES_PLIST="$HOME/Library/LaunchAgents/com.turublok.eyes.plist"
APP_DIR="$HOME/Applications/Turublok.app"
CLI_LINK="$HOME/.local/bin/turublok"
STATE_DIR="$HOME/Library/Application Support/turublok"

echo "==> Unload launchd agents"
launchctl unload "$LOCK_PLIST" 2>/dev/null || true
launchctl unload "$EYES_PLIST" 2>/dev/null || true

echo "==> Remove plists"
rm -f "$LOCK_PLIST" "$EYES_PLIST"

echo "==> Remove app bundle"
rm -rf "$APP_DIR"

echo "==> Remove CLI symlink"
rm -f "$CLI_LINK"

echo "==> Remove state"
rm -rf "$STATE_DIR"

echo "==> Kill any running turublok process"
pkill -9 turublok 2>/dev/null || true

echo "==> Uninstall selesai. Logs masih ada di ~/Projects/TURU-BLOK/logs/"
echo "   Permissions di System Settings (Accessibility/Camera) perlu di-remove manual kalau mau."
