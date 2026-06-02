#!/usr/bin/env bash
set -euo pipefail

PLISTS=(
    "$HOME/Library/LaunchAgents/com.turublok.lock.plist"
    "$HOME/Library/LaunchAgents/com.turublok.eyes.plist"
    "$HOME/Library/LaunchAgents/com.turublok.forcelock.plist"
    "$HOME/Library/LaunchAgents/com.turublok.web.plist"
)
APP_DIR="$HOME/Applications/Turublok.app"
CLI_LINK="$HOME/.local/bin/turublok"
STATE_DIR="$HOME/Library/Application Support/turublok"

echo "==> Unload launchd agents"
for plist in "${PLISTS[@]}"; do
    launchctl unload "$plist" 2>/dev/null || true
done

echo "==> Remove plists"
rm -f "${PLISTS[@]}"

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
