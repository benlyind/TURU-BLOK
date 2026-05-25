#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="$ROOT/assets"

usage() {
    cat <<EOF
Usage: $0 <input-greenscreen-video> [options]

Convert greenscreen video → ProRes 4444 with alpha channel.
Hasil output: $ASSETS/cat_alpha.mov

Options:
  --color HEX       Warna greenscreen (default: 0x00C000 hijau)
  --similarity N    Tolerance warna 0.0-1.0 (default: 0.30)
  --blend N         Softening edge 0.0-1.0 (default: 0.12)
  --resize HxV      Resize output, contoh: 1920x1080 (default: keep original)
  --hd              Shortcut --resize 1920x1080
  --preview         Cuma extract 3 detik buat preview cepat

Contoh:
  $0 ~/Downloads/source.mov
  $0 ~/Downloads/source.mov --hd
  $0 ~/Downloads/source.mov --similarity 0.25 --blend 0.15
  $0 ~/Downloads/source.mov --preview
EOF
    exit 1
}

[[ $# -ge 1 ]] || usage
INPUT="$1"; shift
[[ -f "$INPUT" ]] || { echo "File ga ada: $INPUT" >&2; exit 1; }

COLOR="0x00E101"
SIMILARITY="0.18"
BLEND="0.08"
DESPILL="0.7"
RESIZE=""
PREVIEW=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --color) COLOR="$2"; shift 2;;
        --similarity) SIMILARITY="$2"; shift 2;;
        --blend) BLEND="$2"; shift 2;;
        --resize) RESIZE="$2"; shift 2;;
        --hd) RESIZE="1920x1080"; shift;;
        --preview) PREVIEW="1"; shift;;
        *) echo "unknown: $1" >&2; usage;;
    esac
done

OUTPUT="$ASSETS/cat_alpha.mov"
mkdir -p "$ASSETS"

VF="chromakey=${COLOR}:${SIMILARITY}:${BLEND},despill=type=green:mix=${DESPILL}"
if [[ -n "$RESIZE" ]]; then
    W="${RESIZE%x*}"; H="${RESIZE#*x}"
    VF="${VF},scale=${W}:${H}:flags=lanczos"
fi
VF="${VF},format=yuva444p10le"

PREVIEW_FLAGS=""
if [[ -n "$PREVIEW" ]]; then
    PREVIEW_FLAGS="-t 3"
    OUTPUT="$ASSETS/cat_alpha_preview.mov"
fi

echo "==> Input:  $INPUT"
echo "==> Output: $OUTPUT"
echo "==> Filter: $VF"
echo "==> Codec:  ProRes 4444 (alpha channel)"
echo ""

ffmpeg -y -i "$INPUT" \
    $PREVIEW_FLAGS \
    -vf "$VF" \
    -c:v prores_ks -profile:v 4444 -pix_fmt yuva444p10le \
    -an \
    "$OUTPUT"

echo ""
echo "==> Done. Size: $(du -h "$OUTPUT" | cut -f1)"

if [[ -z "$PREVIEW" ]]; then
    echo ""
    echo "==> Bersihin file lama biar app pakai yang baru:"
    for old in "$ASSETS"/*.mov; do
        [[ "$old" == "$OUTPUT" ]] && continue
        [[ -L "$old" ]] && { echo "    rm symlink: $old"; rm "$old"; }
    done
    echo ""
    echo "==> Sekarang test:"
    echo "    ./scripts/test.sh 15"
fi
