#!/bin/zsh
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_BUILD="$ROOT/build/Jarvis.app"
INSTALLED_APP="$HOME/Jarvis/App/Jarvis.app"
CODESIGN_REQUIREMENT='=designated => identifier "dev.pbbuilds.jarvis"'
ACTIVE_MACOS_SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
SWIFT_SDK_ARGS=(
  -sdk "$ACTIVE_MACOS_SDK"
  -target arm64-apple-macos14.0
)
SDK_SWIFT_INTERFACE="$(/usr/bin/find \
  "$ACTIVE_MACOS_SDK/usr/lib/swift/Swift.swiftmodule" \
  -name '*-apple-macos.swiftinterface' -print -quit 2>/dev/null || true)"
SDK_SWIFT_VERSION=""
if [[ -n "$SDK_SWIFT_INTERFACE" ]]; then
  SDK_SWIFT_VERSION="$(/usr/bin/sed -nE \
    's/^\/\/ swift-compiler-version: Apple Swift version ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' \
    "$SDK_SWIFT_INTERFACE" | /usr/bin/head -n 1)"
fi
SWIFT_COMPILER_VERSION="$(/usr/bin/swiftc --version | /usr/bin/sed -nE \
  's/.*Apple Swift version ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | /usr/bin/head -n 1)"
if [[ -n "$SDK_SWIFT_VERSION" \
      && -n "$SWIFT_COMPILER_VERSION" \
      && "$SDK_SWIFT_VERSION" != "$SWIFT_COMPILER_VERSION" ]]; then
  SWIFT_SDK_ARGS+=(
    -Xfrontend -interface-compiler-version
    -Xfrontend "$SDK_SWIFT_VERSION"
  )
fi

echo "Stopping the current Jarvis app..."
/usr/bin/pkill -x Jarvis 2>/dev/null || true
/bin/sleep 1

echo "Building one canonical Jarvis executable..."
/bin/mkdir -p "$ROOT/build"
/usr/bin/swiftc "$ROOT/native/JarvisMenuBar.swift" \
  "${SWIFT_SDK_ARGS[@]}" \
  -O \
  -o "$ROOT/build/Jarvis" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework AVFoundation \
  -framework Carbon \
  -framework CoreAudio \
  -framework CoreGraphics \
  -framework QuartzCore \
  -framework ScreenCaptureKit \
  -framework ServiceManagement \
  -framework Speech

/bin/rm -rf "$APP_BUILD"
/bin/mkdir -p "$APP_BUILD/Contents/MacOS" "$APP_BUILD/Contents/Resources"
/bin/cp "$ROOT/build/Jarvis" "$APP_BUILD/Contents/MacOS/Jarvis"
/bin/cp "$ROOT/native/MenuInfo.plist" "$APP_BUILD/Contents/Info.plist"

if [[ -d "$ROOT/assets/Jarvis.iconset" ]]; then
  /usr/bin/iconutil -c icns "$ROOT/assets/Jarvis.iconset" \
    -o "$APP_BUILD/Contents/Resources/Jarvis.icns" || true
fi

/usr/bin/codesign --force --deep --sign - --options runtime \
  --entitlements "$ROOT/native/Jarvis.entitlements" \
  --requirements "$CODESIGN_REQUIREMENT" "$APP_BUILD"
/usr/bin/codesign --verify --deep --strict "$APP_BUILD"

echo "Installing the repaired app..."
/bin/mkdir -p "$HOME/Jarvis/App"
/bin/rm -rf "$INSTALLED_APP"
/usr/bin/ditto "$APP_BUILD" "$INSTALLED_APP"

echo "Resetting only Jarvis's stale Screen Recording and Accessibility permissions..."
/usr/bin/tccutil reset ScreenCapture dev.pbbuilds.jarvis
/usr/bin/tccutil reset Accessibility dev.pbbuilds.jarvis

echo "Opening the repaired Jarvis app..."
/usr/bin/open "$INSTALLED_APP"

echo
echo "Jarvis screen capture repair is installed."
echo "Click Allow on the macOS recording prompt, then fully quit and reopen Jarvis once."
