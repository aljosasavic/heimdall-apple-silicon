#!/bin/bash
# Build HeimdallFront.app: SwiftUI front end with the patched heimdall bundled inside.
# Needs: Xcode Command Line Tools, heimdall built in ../build/bin (run ../build.sh), and `brew install lz4`.
set -euo pipefail
cd "$(dirname "$0")"

HEIMDALL=../build/bin/heimdall
[ -x "$HEIMDALL" ] || { echo "heimdall not built yet: run ../build.sh first"; exit 1; }

swift build -c release
BIN="$(swift build -c release --show-bin-path)/HeimdallFront"
"$BIN" --selftest

APP=build/HeimdallFront.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HeimdallFront"
# shortcut: heimdall links libusb from /opt/homebrew, so the app needs `brew install libusb` on the Mac it runs on;
# bundle the dylib (install_name_tool) before distributing it to other machines
cp "$HEIMDALL" "$APP/Contents/Resources/heimdall"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Heimdall</string>
    <key>CFBundleDisplayName</key><string>Heimdall</string>
    <key>CFBundleIdentifier</key><string>local.heimdall.front</string>
    <key>CFBundleExecutable</key><string>HeimdallFront</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP/Contents/Resources/heimdall"
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
