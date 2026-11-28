#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/AndroidConnection.app"
ICONSET="$BUILD_DIR/AppIcon.iconset"
ICON="$BUILD_DIR/AppIcon.icns"

mkdir -p "$BUILD_DIR"

if [ ! -f "$ICON" ]; then
  echo "==> Generating application icon"
  swift "$ROOT/Tools/make_icon.swift" "$ICONSET"
  iconutil -c icns "$ICONSET" -o "$ICON"
fi

echo "==> Building universal binary (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64

echo "==> Assembling application bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp -f "$ROOT/.build/release/AndroidConnection" "$APP/Contents/MacOS/AndroidConnection"
cp -f "$ROOT/Vendor/adb" "$APP/Contents/Resources/adb"
cp -f "$ROOT/Vendor/scrcpy-server.jar" "$APP/Contents/Resources/scrcpy-server.jar"
cp -f "$ICON" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>AndroidConnection</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.androidconnection.mac</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>AndroidConnection</string>
    <key>CFBundleDisplayName</key>
    <string>AndroidConnection</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.2.21</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 AndroidConnection. Local-only ADB device manager.</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"
chmod +x "$APP/Contents/MacOS/AndroidConnection" "$APP/Contents/Resources/adb"

echo "==> Stripping debug symbols"
strip -S "$APP/Contents/MacOS/AndroidConnection" 2>/dev/null || true

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP"

echo "==> Done"
echo "App: $APP"
lipo -archs "$APP/Contents/MacOS/AndroidConnection"
