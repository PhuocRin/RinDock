#!/bin/bash
# Build RinDock.app (chạy được trên cả Mac chip Apple và Mac Intel).
# GitHub tự chạy file này mỗi khi có bản mới, nên thường không cần chạy tay.
#   ./build.sh           → build ra build/RinDock.app
#   ./build.sh dmg       → build + tạo file cài .dmg (kéo thả vào Applications)
#   ./build.sh install   → build + chép vào /Applications + mở app
set -euo pipefail
export LC_ALL=en_US.UTF-8
cd "$(dirname "$0")"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Máy chưa có công cụ build Swift. Chạy lệnh này, cài xong rồi chạy lại ./build.sh:"
  echo "  xcode-select --install"
  exit 1
fi

APP="build/RinDock.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"

# ---------------------------------------------------------------- build app
echo "→ Đang build RinDock ${VERSION}…"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

for ARCH in arm64 x86_64; do
  xcrun swiftc -O \
    -target "$ARCH-apple-macos13.0" \
    Sources/main.swift \
    -o "build/obj/RinDock-$ARCH" \
    -swift-version 5 -parse-as-library \
    -framework Cocoa -framework ApplicationServices -framework ServiceManagement -framework SwiftUI
done
lipo -create build/obj/RinDock-arm64 build/obj/RinDock-x86_64 -output "$APP/Contents/MacOS/RinDock"

cp Info.plist "$APP/Contents/Info.plist"
# Icon app.
iconutil -c icns assets/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
# Ảnh QR ủng hộ (nếu có) đóng gói vào app.
if [[ -f assets/donate-qr.png ]]; then
  cp assets/donate-qr.png "$APP/Contents/Resources/donate-qr.png"
fi
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "✓ Xong: $APP"

# ---------------------------------------------------------------- .dmg
make_dmg() {
  local DMG="build/RinDock-$VERSION.dmg"
  echo "→ Đang tạo file cài .dmg…"
  python3 -m venv build/.venv
  build/.venv/bin/pip install --quiet --disable-pip-version-check dmgbuild
  build/.venv/bin/dmgbuild -s dmg_settings.py -D app="$APP" "RinDock" "$DMG"
  echo "✓ File cài: $DMG"
}

case "${1:-}" in
  dmg)
    make_dmg
    ;;
  install)
    pkill -x RinDock 2>/dev/null || true
    rm -rf /Applications/RinDock.app
    cp -R "$APP" /Applications/
    echo "✓ Đã chép vào /Applications"
    open /Applications/RinDock.app
    ;;
esac
