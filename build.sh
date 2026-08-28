#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/dist"
WORK="$ROOT/.build"
APP="$DIST/SSTP Client GUI.app"
BIN="$APP/Contents/MacOS/SSTPClientGUI"
RES="$ROOT/Resources"
TOOLS="$ROOT/Tools"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
INSTALL_APP=0
OPEN_APP=0
INSTALL_ONLY=0
BUILD_IN_PROGRESS=0

usage() {
  cat <<'EOF'
Usage:
  ./build.sh                 Clean Universal build + ZIP
  ./build.sh --install       Clean build, replace /Applications copy and launch it
  ./build.sh --install-only  Install already-built dist app and launch it
  ./build.sh --help          Show this help

Optional signing:
  SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./build.sh --install
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
      INSTALL_ONLY=1
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

cleanup_on_error() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$BUILD_IN_PROGRESS" -eq 1 ]; then
    echo
    echo "Build failed (exit $rc). Removing incomplete build output..."
    rm -rf "$DIST" "$WORK"
  fi
  exit "$rc"
}
trap cleanup_on_error EXIT

install_app() {
  local target="/Applications/SSTP Client GUI.app"

  if [ ! -d "$APP" ] || [ ! -x "$BIN" ]; then
    echo "Complete build output not found: $APP"
    echo "Run ./build.sh --install first."
    exit 1
  fi

  echo
  echo "Stopping running SSTP Client GUI..."
  /usr/bin/pkill -x SSTPClientGUI >/dev/null 2>&1 || true
  sleep 1

  echo "Replacing application in /Applications..."
  sudo /bin/rm -rf "$target"
  sudo /usr/bin/ditto "$APP" "$target"

  # Local/internal builds are ad-hoc signed unless SIGN_IDENTITY is supplied.
  sudo /usr/bin/xattr -dr com.apple.quarantine "$target" >/dev/null 2>&1 || true

  echo "Verifying installed application..."
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$target"

  echo "Installed version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$target/Contents/Info.plist")"
  echo "Installed build: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$target/Contents/Info.plist")"
  echo "Installed architectures: $(/usr/bin/lipo -archs "$target/Contents/MacOS/SSTPClientGUI")"

  if [ "$OPEN_APP" -eq 1 ]; then
    echo "Launching installed application..."
    /usr/bin/open "$target"
  fi
}

if [ "$INSTALL_ONLY" -eq 1 ]; then
  install_app
  trap - EXIT
  exit 0
fi

BUILD_IN_PROGRESS=1

rm -rf "$DIST" "$WORK"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$WORK"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Swift compiler not found. Install Xcode Command Line Tools:"
  echo "  xcode-select --install"
  exit 1
fi

SDK="$(xcrun --sdk macosx --show-sdk-path)"
SWIFTC="$(xcrun --find swiftc)"
SOURCES=("$ROOT"/Sources/*.swift)

echo "SDK: $SDK"
echo "Swift compiler: $SWIFTC"
echo "Swift sources: ${#SOURCES[@]}"

cp "$RES/vpnctl.sh" "$APP/Contents/Resources/vpnctl.sh"
cp "$RES/setup.sh" "$APP/Contents/Resources/setup.sh"
chmod 755 "$APP/Contents/Resources/vpnctl.sh" "$APP/Contents/Resources/setup.sh"

echo "Generating app icon..."
ICON_TOOL="$WORK/make_icon"
"$SWIFTC" \
  -sdk "$SDK" \
  "$TOOLS/make_icon.swift" \
  -o "$ICON_TOOL" \
  -framework AppKit \
  -framework Foundation
"$ICON_TOOL" "$WORK/AppIcon.iconset"
/usr/bin/iconutil -c icns "$WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

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
  <string>8</string>
  <key>CFBundleShortVersionString</key>
  <string>1.3.2</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

COMMON_ARGS=(
  -parse-as-library
  -swift-version 5
  -sdk "$SDK"
  -framework SwiftUI
  -framework AppKit
  -framework Security
  -framework UserNotifications
)

echo "Building arm64..."
"$SWIFTC" \
  "${COMMON_ARGS[@]}" \
  -target arm64-apple-macos12.0 \
  "${SOURCES[@]}" \
  -o "$WORK/SSTPClientGUI-arm64"

echo "Building x86_64..."
"$SWIFTC" \
  "${COMMON_ARGS[@]}" \
  -target x86_64-apple-macos12.0 \
  "${SOURCES[@]}" \
  -o "$WORK/SSTPClientGUI-x86_64"

/usr/bin/lipo -create \
  "$WORK/SSTPClientGUI-arm64" \
  "$WORK/SSTPClientGUI-x86_64" \
  -output "$BIN"

chmod 755 "$BIN"

/usr/bin/plutil -lint "$APP/Contents/Info.plist"

echo "Signing with: $SIGN_IDENTITY"
/usr/bin/codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"

echo "Architectures: $(/usr/bin/lipo -archs "$BIN")"
echo "Version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
echo "Build: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent \
  "$APP" \
  "$DIST/SSTP-Client-GUI-macOS.zip"

BUILD_IN_PROGRESS=0

echo
echo "Build complete:"
echo "  $APP"
echo "  $DIST/SSTP-Client-GUI-macOS.zip"

if [ "$INSTALL_APP" -eq 1 ]; then
  install_app
fi

trap - EXIT
