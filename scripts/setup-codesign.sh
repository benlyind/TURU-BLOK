#!/usr/bin/env bash
set -euo pipefail

# Bikin self-signed code signing certificate biar TCC (Accessibility) permission
# PERSISTENT across rebuilds. Tanpa ini, tiap rebuild = ad-hoc cdhash baru =
# permission dicabut macOS = CGEventTap gagal = keyboard ga ke-block.
#
# Idempotent: skip kalau cert udah ada.

CERT_CN="Turublok Code Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Pakai system openssl (LibreSSL) — bikin PKCS12 yang kompatibel dengan macOS `security`.
# Homebrew openssl 3.x default-nya pakai algoritma yang Keychain ga bisa baca.
OPENSSL="/usr/bin/openssl"

if security find-certificate -c "$CERT_CN" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "==> Cert '$CERT_CN' udah ada. Skip pembuatan."
    exit 0
fi

echo "==> Bikin self-signed code signing certificate: $CERT_CN"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/cert.conf" <<EOF
[ req ]
distinguished_name = req_dn
x509_extensions = codesign_ext
prompt = no
[ req_dn ]
CN = $CERT_CN
[ codesign_ext ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 \
    -keyout "$TMP_DIR/key.pem" \
    -out "$TMP_DIR/cert.pem" \
    -days 3650 -nodes \
    -config "$TMP_DIR/cert.conf" 2>/dev/null

# LibreSSL (/usr/bin/openssl) bikin PKCS12 yang langsung kompatibel dengan macOS Keychain.
# Password sementara (cuma buat transfer p12) — ga ngaruh ke pemakaian cert.
P12_PASS="turublok-transfer"
"$OPENSSL" pkcs12 -export \
    -inkey "$TMP_DIR/key.pem" \
    -in "$TMP_DIR/cert.pem" \
    -out "$TMP_DIR/bundle.p12" \
    -passout "pass:$P12_PASS" 2>/dev/null

echo "==> Import ke login keychain (kasih akses ke codesign)"
security import "$TMP_DIR/bundle.p12" \
    -k "$KEYCHAIN" \
    -P "$P12_PASS" \
    -T /usr/bin/codesign \
    -T /usr/bin/security

echo ""
echo "==> Cert dibuat. Saat codesign pertama jalan, mungkin muncul popup keychain."
echo "    Klik 'Always Allow' biar ga nanya lagi."
echo ""
echo "    NEXT: jalankan ./scripts/install.sh untuk re-sign + reinstall."
