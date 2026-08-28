#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/dist"
WORK="$ROOT/.build"
APP="$DIST/SSTP Client GUI.app"
BIN="$APP/Contents/MacOS/SSTPClientGUI"
SRC="$ROOT/Sources/SSTPClientGUI.swift"
RES="$ROOT/Resources"
TOOLS="$ROOT/Tools"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
INSTALL_APP=0
OPEN_APP=0

usage() {
  cat <<'EOF'
Usage:
  ./build.sh                 Build Universal app + ZIP
  ./build.sh --install       Clean build, replace /Applications copy and launch it
  ./build.sh --install-only  Install already-built dist app and launch it
EOF
}

for arg in "$@"; do
  case "$arg" in
    --install)
      INSTALL_APP=1
      OPEN_APP=1
      ;;
    --install-only)
      INSTALL_APP=1
      OPEN_APP=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg"
      usage
      exit 2
      ;;
  esac
done

INSTALL_ONLY=0
for arg in "$@"; do
  [ "$arg" = "--install-only" ] && INSTALL_ONLY=1
done

install_app() {
  local target="/Applications/SSTP Client GUI.app"

  if [ ! -d "$APP" ]; then
    echo "Build output not found: $APP"
    exit 1
  fi

  echo
  echo "Stopping running SSTP Client GUI..."
  /usr/bin/pkill -x SSTPClientGUI >/dev/null 2>&1 || true
  sleep 1

  echo "Replacing application in /Applications..."
  sudo /bin/rm -rf "$target"
  sudo /usr/bin/ditto "$APP" "$target"

  # The app is ad-hoc signed unless SIGN_IDENTITY is supplied.
  # Removing quarantine is useful for trusted internal builds copied locally.
  sudo /usr/bin/xattr -dr com.apple.quarantine "$target" >/dev/null 2>&1 || true

  echo "Verifying installed application..."
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$target"

  echo "Installed version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$target/Contents/Info.plist")"
  echo "Installed architectures: $(/usr/bin/lipo -archs "$target/Contents/MacOS/SSTPClientGUI")"

  if [ "$OPEN_APP" -eq 1 ]; then
    echo "Launching installed application..."
    /usr/bin/open "$target"
  fi
}

if [ "$INSTALL_ONLY" -eq 1 ]; then
  install_app
  exit 0
fi

# Always start from a clean local build.
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

# Generate a native .icns file from source so the repository stays text-only.
echo "Generating app icon..."
xcrun swift "$TOOLS/make_icon.swift" "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

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
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleVersion</key>
  <string>4</string>
  <key>CFBundleShortVersionString</key>
  <string>1.2.1</string>
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

if [ "$INSTALL_APP" -eq 1 ]; then
  install_app
fi
