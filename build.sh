#!/bin/bash
# Build RinDock.app (chạy được trên cả Mac chip Apple và Mac Intel).
# GitHub tự chạy file này mỗi khi có bản mới, nên thường không cần chạy tay.
#   ./build.sh           → build ra build/RinDock.app
#   ./build.sh dmg       → build + tạo file cài .dmg (kéo thả vào Applications)
#   ./build.sh release   → build + .dmg + gói cập nhật .zip (+ chữ ký .sig nếu có UPDATE_KEY)
#   ./build.sh install   → build + chép vào /Applications + mở app
#
# Ký app: đặt SIGN_IDENTITY (tên hoặc mã SHA-1 chứng chỉ) và SIGN_KEYCHAIN thì ký bằng chứng chỉ đó
# (giữ quyền Accessibility qua các bản). Không đặt thì ký ad-hoc (chỉ để thử trên máy mình).
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
xcrun swiftc --version 2>&1 | head -1
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
# Icon thanh menu (đơn sắc, tự đổi theo nền sáng/tối).
cp assets/menubar/MenuBarIcon*.png "$APP/Contents/Resources/"
# Ảnh QR ủng hộ (nếu có) đóng gói vào app.
if [[ -f assets/donate-qr.png ]]; then
  cp assets/donate-qr.png "$APP/Contents/Resources/donate-qr.png"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "⚠ Ký ad-hoc (không có chứng chỉ). Bản này mỗi lần cập nhật sẽ phải cấp lại quyền."
  codesign --force --sign - --identifier com.phuocrin.rindock "$APP"
else
  codesign --force --timestamp=none --sign "$SIGN_IDENTITY" \
    ${SIGN_KEYCHAIN:+--keychain "$SIGN_KEYCHAIN"} \
    --identifier com.phuocrin.rindock "$APP"
fi
codesign --verify --strict "$APP"
echo "→ Yêu cầu chữ ký (designated requirement):"
codesign -d -r- "$APP" 2>&1 | grep -i designated || true
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

# ---------------------------------------------------------------- gói cập nhật
make_update_zip() {
  local ZIP="build/RinDock-$VERSION.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "✓ Gói cập nhật: $ZIP"
  if [[ -n "${UPDATE_KEY:-}" ]]; then
    build/.venv/bin/pip install --quiet --disable-pip-version-check cryptography
    ZIP="$ZIP" build/.venv/bin/python - <<'PY'
import base64, os
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
key = Ed25519PrivateKey.from_private_bytes(base64.b64decode(os.environ["UPDATE_KEY"]))
path = os.environ["ZIP"]
sig = key.sign(open(path, "rb").read())
open(path + ".sig", "w").write(base64.b64encode(sig).decode())
PY
    echo "✓ Chữ ký gói cập nhật: $ZIP.sig"
  else
    echo "⚠ Không có UPDATE_KEY: gói cập nhật chưa được ký, app sẽ không tự cài gói này."
  fi
}

case "${1:-}" in
  dmg)
    make_dmg
    ;;
  release)
    make_dmg
    make_update_zip
    ;;
  install)
    pkill -x RinDock 2>/dev/null || true
    rm -rf /Applications/RinDock.app
    cp -R "$APP" /Applications/
    echo "✓ Đã chép vào /Applications"
    open /Applications/RinDock.app
    ;;
esac
