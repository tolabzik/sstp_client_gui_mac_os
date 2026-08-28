#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/dist"
WORK="$ROOT/.build"
APP="$DIST/SSTP Client GUI.app"
BIN="$APP/Contents/MacOS/SSTPClientGUI"
SRC="$ROOT/Sources/SSTPClientGUI.swift"
RES="$ROOT/Resources"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

rm -rf "$DIST" "$WORK"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$WORK"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Swift compiler not found. Install Xcode Command Line Tools:"
  echo "  xcode-select --install"
  exit 1
fi

cp "$RES/vpnctl.sh" "$APP/Contents/Resources/vpnctl.sh"
cp "$RES/setup.sh" "$APP/Contents/Resources/setup.sh"
chmod 755 "$APP/Contents/Resources/vpnctl.sh" "$APP/Contents/Resources/setup.sh"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
"http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>SSTP Client GUI</string>
  <key>CFBundleDisplayName</key>
  <string>SSTP Client GUI</string>
  <key>CFBundleExecutable</key>
  <string>SSTPClientGUI</string>
  <key>CFBundleIdentifier</key>
  <string>io.github.tolabzik.sstp-client-gui</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>2</string>
  <key>CFBundleShortVersionString</key>
  <string>1.1.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

SDK="$(xcrun --sdk macosx --show-sdk-path)"

echo "Building arm64..."
xcrun swiftc \
  -parse-as-library \
  -swift-version 5 \
  -target arm64-apple-macos12.0 \
  -sdk "$SDK" \
  "$SRC" \
  -o "$WORK/SSTPClientGUI-arm64" \
  -framework SwiftUI \
  -framework AppKit \
  -framework Security

echo "Building x86_64..."
xcrun swiftc \
  -parse-as-library \
  -swift-version 5 \
  -target x86_64-apple-macos12.0 \
  -sdk "$SDK" \
  "$SRC" \
  -o "$WORK/SSTPClientGUI-x86_64" \
  -framework SwiftUI \
  -framework AppKit \
  -framework Security

lipo -create \
  "$WORK/SSTPClientGUI-arm64" \
  "$WORK/SSTPClientGUI-x86_64" \
  -output "$BIN"

chmod 755 "$BIN"

plutil -lint "$APP/Contents/Info.plist"

echo "Signing with: $SIGN_IDENTITY"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

echo "Architectures: $(lipo -archs "$BIN")"

ditto -c -k --sequesterRsrc --keepParent \
  "$APP" \
  "$DIST/SSTP-Client-GUI-macOS.zip"

echo
echo "Build complete:"
echo "  $APP"
echo "  $DIST/SSTP-Client-GUI-macOS.zip"
