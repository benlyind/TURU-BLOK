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
FORCE_PLIST_SRC="$ROOT/launchd/com.turublok.forcelock.plist"
FORCE_PLIST_DST="$HOME/Library/LaunchAgents/com.turublok.forcelock.plist"
WEB_PLIST_SRC="$ROOT/launchd/com.turublok.web.plist"
WEB_PLIST_DST="$HOME/Library/LaunchAgents/com.turublok.web.plist"
WEB_SERVER="$ROOT/web/server.py"

if [[ ! -x "$BIN_SRC" ]]; then
    echo "Binary belum di-build. Jalankan: scripts/build.sh" >&2
    exit 1
fi

# Video kucing disimpen di repo sebagai .zip (file mentah-nya gede). Extract kalau belum.
if [[ ! -f "$ROOT/assets/cat.mov" && -f "$ROOT/assets/cat.mov.zip" ]]; then
    echo "==> Extract video kucing dari cat.mov.zip"
    ( cd "$ROOT/assets" && unzip -o -q cat.mov.zip )
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
    <string>Sleeping My Love</string>
    <key>CFBundleDisplayName</key>
    <string>Sleeping My Love</string>
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

# Code sign dengan self-signed cert biar TCC (Accessibility) permission PERSISTENT.
# Tanpa ini = ad-hoc signature = cdhash berubah tiap rebuild = permission dicabut.
CERT_CN="Turublok Code Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_CN"; then
    echo "==> Code sign dengan '$CERT_CN'"
    codesign --force --deep --sign "$CERT_CN" "$APP_DIR"
    codesign --verify --verbose "$APP_DIR" 2>&1 | head -2 || true
else
    echo "⚠️  Cert '$CERT_CN' belum ada. Jalankan dulu: ./scripts/setup-codesign.sh" >&2
    echo "    (tanpa cert, keyboard blocking GA AKAN jalan setelah rebuild)" >&2
fi

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
sed -e "s|__BINARY_PATH__|$APP_BIN|g" -e "s|__HOME__|$HOME|g" \
    "$FORCE_PLIST_SRC" > "$FORCE_PLIST_DST"
sed -e "s|__WEB_SERVER__|$WEB_SERVER|g" -e "s|__HOME__|$HOME|g" \
    "$WEB_PLIST_SRC" > "$WEB_PLIST_DST"

echo "==> Touch skip-next sentinel (prevent install-time spurious lock)"
SUPPORT_DIR="$HOME/Library/Application Support/turublok"
mkdir -p "$SUPPORT_DIR"
touch "$SUPPORT_DIR/skip-next.flag"

# Default PIN awal = 1111 (cuma buat pairing pertama). Keamanan beneran dateng
# dari istri ganti PIN rahasia lewat PWA (disimpan ter-hash). Default sengaja simpel.
WEB_CONFIG="$SUPPORT_DIR/web_config.json"
if [[ ! -f "$WEB_CONFIG" ]]; then
    GEN_PIN="1111"
    ( umask 077; printf '{"pin":"%s","tokens":[]}\n' "$GEN_PIN" > "$WEB_CONFIG" )
    chmod 600 "$WEB_CONFIG"
    echo "==> Default control-panel PIN: $GEN_PIN (istri ganti lewat PWA setelah pair)"
else
    chmod 600 "$WEB_CONFIG" 2>/dev/null || true
    GEN_PIN=$(/usr/bin/python3 -c "import json;d=json.load(open('$WEB_CONFIG'));print(d.get('pin','(custom/hashed)'))" 2>/dev/null || echo "(lihat $WEB_CONFIG)")
fi

echo "==> Load launchd agents"
for plist in "$LOCK_PLIST_DST" "$EYES_PLIST_DST" "$FORCE_PLIST_DST" "$WEB_PLIST_DST"; do
    launchctl unload "$plist" 2>/dev/null || true
done
launchctl load -w "$LOCK_PLIST_DST"
launchctl load -w "$EYES_PLIST_DST"
launchctl load -w "$FORCE_PLIST_DST"
launchctl load -w "$WEB_PLIST_DST"

# Cari LAN hostname + IP buat akses dari HP.
LOCAL_HOST="$(scutil --get LocalHostName 2>/dev/null || echo turublok).local"
LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo '<ip-mac>')"

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
  • Control panel (HP)  : http://$LOCAL_HOST:8787
                          (atau http://$LAN_IP:8787 kalau .local ga jalan)

═══════════════════════════════════════════════════════
  buat istri — "Sleeping My Love" 💤

  1. samain WiFi HP sama Mac ya
  2. buka di Safari:  http://$LOCAL_HOST:8787
  3. PIN-nya: $GEN_PIN
  4. Share → "Add to Home Screen" → jadi app "Sleeping My Love"
  5. abis masuk, tap "ganti PIN rahasia" — ganti aja biar
     suamimu ga bisa akses, jangan kasih tau dia ya 🤫

  tombol:
    😴 Tidur Sayang     → kunci layar sekarang
    ☀️ Boleh Kerja      → buka kuncinya
    🌙 Izin Begadang    → boleh melek sampai jam yg kamu pilih
    🚫 Jangan Begadang  → batalin izin, suruh tidur
═══════════════════════════════════════════════════════

TROUBLESHOOTING:

  Cek schedule          : launchctl list | grep turublok
  Cek status            : $CLI_LINK --status
  Cek log lock          : tail -f $ROOT/logs/turublok.log
  Cek log eye-watch     : tail -f $ROOT/logs/eyes.out.log
  Test lock 30 detik    : $ROOT/scripts/test.sh 30
  Uninstall             : $ROOT/scripts/uninstall.sh

EOF
