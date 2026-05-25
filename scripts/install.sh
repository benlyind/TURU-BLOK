#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_SRC="$ROOT/app/.build/release/turublok"

APP_DIR="$HOME/Applications/Turublok.app"
APP_BIN="$APP_DIR/Contents/MacOS/turublok"
CLI_LINK="$HOME/.local/bin/turublok"

LOCK_PLIST_SRC="$ROOT/launchd/com.turublok.lock.plist"
LOCK_PLIST_DST="$HOME/Library/LaunchAgents/com.turublok.lock.plist"
EYES_PLIST_SRC="$ROOT/launchd/com.turublok.eyes.plist"
EYES_PLIST_DST="$HOME/Library/LaunchAgents/com.turublok.eyes.plist"

if [[ ! -x "$BIN_SRC" ]]; then
    echo "Binary belum di-build. Jalankan: scripts/build.sh" >&2
    exit 1
fi

echo "==> Build .app bundle -> $APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BIN_SRC" "$APP_BIN"
chmod 755 "$APP_BIN"

echo "==> Generate Info.plist (Camera + Accessibility usage descriptions)"
cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>turublok</string>
    <key>CFBundleIdentifier</key>
    <string>com.turublok.app</string>
    <key>CFBundleName</key>
    <string>Turublok</string>
    <key>CFBundleDisplayName</key>
    <string>Turublok</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSCameraUsageDescription</key>
    <string>Untuk deteksi kelelahan mata via blink rate. Semua proses lokal, tidak ada video disimpan atau dikirim ke mana pun.</string>
</dict>
</plist>
EOF

# Force LaunchServices re-register supaya Info.plist baru ke-pick-up.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR" 2>/dev/null || true

echo "==> CLI wrapper -> $CLI_LINK"
mkdir -p "$(dirname "$CLI_LINK")"
ln -sf "$APP_BIN" "$CLI_LINK"

echo "==> Generate launchd plists"
mkdir -p "$(dirname "$LOCK_PLIST_DST")"
sed -e "s|__BINARY_PATH__|$APP_BIN|g" -e "s|__HOME__|$HOME|g" \
    "$LOCK_PLIST_SRC" > "$LOCK_PLIST_DST"
sed -e "s|__BINARY_PATH__|$APP_BIN|g" -e "s|__HOME__|$HOME|g" \
    "$EYES_PLIST_SRC" > "$EYES_PLIST_DST"

echo "==> Touch skip-next sentinel (prevent install-time spurious lock)"
SUPPORT_DIR="$HOME/Library/Application Support/turublok"
mkdir -p "$SUPPORT_DIR"
touch "$SUPPORT_DIR/skip-next.flag"

echo "==> Load launchd agents"
launchctl unload "$LOCK_PLIST_DST" 2>/dev/null || true
launchctl unload "$EYES_PLIST_DST" 2>/dev/null || true
launchctl load -w "$LOCK_PLIST_DST"
launchctl load -w "$EYES_PLIST_DST"

cat <<EOF

==> Install selesai.

YANG PERLU DIAPPROVE DI System Settings → Privacy & Security:

  1. Accessibility (untuk block keyboard shortcut saat lock)
     → Klik +, tambahin: $APP_DIR
     (atau drag-drop Turublok.app dari Finder)

  2. Camera (untuk deteksi mata capek)
     → Otomatis muncul prompt pas pertama kali eye-watch jalan.
     → Atau tambah manual: $APP_DIR

KOMPONEN YANG JALAN:

  • Bedtime lock        : 23:00 - 07:00 WIB (auto-resume kalau Mac di-restart)
  • Eye-watch           : aktif tiap hari mulai 08:00 WIB
                          → kalau > 60 menit kerja non-stop + mata capek terdeteksi
                          → trigger 10 menit kucing break

TROUBLESHOOTING:

  Cek schedule          : launchctl list | grep turublok
  Cek status            : $CLI_LINK --status
  Cek log lock          : tail -f $ROOT/logs/turublok.log
  Cek log eye-watch     : tail -f $ROOT/logs/eyes.out.log
  Test lock 30 detik    : $ROOT/scripts/test.sh 30
  Uninstall             : $ROOT/scripts/uninstall.sh

EOF
