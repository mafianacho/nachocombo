#!/bin/bash
# Builds NachoCombo.app (ad-hoc signed, LSUIElement) on macOS 12+. Output: build/NachoCombo.app
# BUILD_MODE=spm   (default) uses SwiftPM (needs a toolchain whose PackageDescription module is present)
# BUILD_MODE=swiftc uses swiftc directly (works with a bare Command Line Tools install)
# UNIVERSAL=1      (spm mode) builds a universal binary (arm64 + x86_64)
# VERSION=x.y.z    sets CFBundleShortVersionString (default 0.3.0)
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${BUILD_MODE:-spm}"
CONFIG="${CONFIG:-release}"
VERSION="${VERSION:-0.3.0}"
APP="build/NachoCombo.app"
mkdir -p build
if [ "$MODE" = "spm" ]; then
  ARCH_ARGS=()
  [ "${UNIVERSAL:-0}" = "1" ] && ARCH_ARGS=(--arch arm64 --arch x86_64)
  swift build -c "$CONFIG" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
  BIN="$(swift build -c "$CONFIG" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)/NachoCombo"
else
  TARGET="x86_64-apple-macos12.0"; [ "$(uname -m)" = "arm64" ] && TARGET="arm64-apple-macos12.0"
  rm -f build/NachoComboCore.o build/NachoComboCore.swiftmodule
  swiftc -O -target "$TARGET" -module-name NachoComboCore -parse-as-library -wmo \
    -emit-module -emit-module-path build/NachoComboCore.swiftmodule \
    -c Sources/NachoComboCore/*.swift -o build/NachoComboCore.o
  swiftc -O -target "$TARGET" -module-name NachoCombo -I build \
    build/NachoComboCore.o Sources/NachoCombo/*.swift -o build/NachoCombo-bin
  BIN="build/NachoCombo-bin"
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/NachoCombo"
# App icon: every size macOS asks for, made from the 1024 px master.
if [ -f Resources/AppIcon.png ]; then
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET" "$APP/Contents/Resources"
  for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi
# Brand fonts (SIL Open Font License, licenses beside them); the app registers them at launch.
if [ -d Resources/Fonts ]; then
  mkdir -p "$APP/Contents/Resources/Fonts"
  cp Resources/Fonts/*.ttf Resources/Fonts/*.txt "$APP/Contents/Resources/Fonts/"
fi
# Drop debug-map entries so build-machine paths are not embedded in the release binary.
strip -S -x "$APP/Contents/MacOS/NachoCombo"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.mafianacho.nachocombo</string>
<key>CFBundleName</key><string>Nacho Combo</string>
<key>CFBundleExecutable</key><string>NachoCombo</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>LSUIElement</key><true/>
<key>NSCalendarsUsageDescription</key><string>Calendar Clock shows your events and meeting links. Events are read on this Mac and never sent anywhere.</string>
<key>NSCalendarsFullAccessUsageDescription</key><string>Calendar Clock shows your events and meeting links. Events are read on this Mac and never sent anywhere.</string>
<key>NSDesktopFolderUsageDescription</key><string>Disk Map reads the names and sizes in this folder to map your disk. Nothing leaves this Mac.</string>
<key>NSDocumentsFolderUsageDescription</key><string>Disk Map reads the names and sizes in this folder to map your disk. Nothing leaves this Mac.</string>
<key>NSDownloadsFolderUsageDescription</key><string>Disk Map reads the names and sizes in this folder to map your disk. Nothing leaves this Mac.</string>
<key>NSRemovableVolumesUsageDescription</key><string>Disk Map reads the names and sizes on this disk to map it. Nothing leaves this Mac.</string>
<key>NSNetworkVolumesUsageDescription</key><string>Disk Map reads the names and sizes on this volume to map it. Nothing leaves this Mac.</string>
<key>NSFileProviderDomainUsageDescription</key><string>Disk Map reads the names and sizes of your cloud folders to map your disk. Nothing is downloaded.</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSLocalNetworkUsageDescription</key><string>Only when Computer Use's LAN mode is on: Nacho Combo opens its server to other computers on the same network (and, if you choose, announces it with Bonjour).</string>
<key>NSBonjourServices</key><array><string>_nacho-mcp._tcp</string></array>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "built $APP"
