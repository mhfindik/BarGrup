#!/bin/bash
# BarGrup.app paketini derler ve imzalar.
# Kullanım: ./build.sh                 ("BarGrup Self-Signed" sertifikası, yoksa ad-hoc)
#           UNIVERSAL=1 ./build.sh      (Apple Silicon + Intel)
#           SIGN_ID="Developer ID Application: …" ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

# UNIVERSAL=1 → Apple Silicon + Intel (arm64 + x86_64) tek ikili.
ARCH_FLAGS=()
if [ "${UNIVERSAL:-0}" = "1" ]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi
swift build -c release "${ARCH_FLAGS[@]}"
BIN_DIR=$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)

APP="build/BarGrup.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/BarGrup" "$APP/Contents/MacOS/BarGrup"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "Resources/AppIcon.icns" ]; then
  cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Varsayılan: anahtar zincirindeki "BarGrup Self-Signed" sertifikası (yoksa ad-hoc).
# Kimlik gereksinimi paket kimliğine sabitlenir; böylece Erişilebilirlik izni
# yeniden derlemelerde ve imza türü değişse bile korunur.
if [ -z "${SIGN_ID:-}" ]; then
  SIGN_ID=$(security find-identity -p codesigning 2>/dev/null | awk '/"BarGrup Self-Signed"/ {print $2; exit}')
  SIGN_ID=${SIGN_ID:--}
fi
codesign --force --options runtime --timestamp=none --sign "$SIGN_ID" \
  -r='designated => identifier "com.mhf.BarGrup"' "$APP"
echo "Hazır: $(pwd)/$APP"
