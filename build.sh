#!/bin/zsh
# Builds build/Traceless.app with the Xcode toolchain. Usage: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Traceless.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ ! -f Resources/AppIcon.icns ]]; then
  ICONSET=build/AppIcon.iconset; mkdir -p "$ICONSET"
  swift Tools/make-icon.swift build/icon-1024.png
  for sz in 16 32 128 256 512; do
    sips -z $sz $sz build/icon-1024.png --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
    sips -z $((sz*2)) $((sz*2)) build/icon-1024.png --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi
swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos26.0 \
  Sources/*.swift -o "$APP/Contents/MacOS/Traceless"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP"
