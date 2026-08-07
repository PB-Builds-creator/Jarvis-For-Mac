#!/bin/bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
JARVIS_ROOT="${JARVIS_ROOT:-$HOME/Jarvis}"
JARVIS_VERIFICATION_BUILD="${JARVIS_VERIFICATION_BUILD:-0}"
CODESIGN_REQUIREMENT='=designated => identifier "dev.pbbuilds.jarvis"'
DATA_DIR="$JARVIS_ROOT/Data"
APP_DIR="$JARVIS_ROOT/App"
INFO_DIR="$JARVIS_ROOT/Information"

if [[ "${JARVIS_NONINTERACTIVE:-0}" != "1" ]]; then clear; fi
printf '\nJarvis for macOS — Advanced Foundation v1.0\n'
printf '================================================\n\n'

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer must be run on macOS."
  read -r -p "Press Return to close..."
  exit 1
fi

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "This build is intended for an Apple-silicon Mac."
  read -r -p "Press Return to close..."
  exit 1
fi

mkdir -p "$DATA_DIR/bin" "$DATA_DIR/logs" "$DATA_DIR/backups" "$DATA_DIR/runtime" "$APP_DIR" \
  "$INFO_DIR/Screenshots" "$INFO_DIR/Memory Exports" "$INFO_DIR/Inbox" \
  "$INFO_DIR/Trading/Chart Reviews" "$INFO_DIR/Trading/Trade Journal" \
  "$INFO_DIR/Personal Notes" "$INFO_DIR/Project Notes"
if [[ ! -e "$DATA_DIR/screenshots" ]]; then ln -s "../Information/Screenshots" "$DATA_DIR/screenshots"; fi
if [[ ! -e "$DATA_DIR/exports" ]]; then ln -s "../Information/Memory Exports" "$DATA_DIR/exports"; fi
if [[ ! -e "$DATA_DIR/inbox" ]]; then ln -s "../Information/Inbox" "$DATA_DIR/inbox"; fi
printf '%s\n' "$ROOT" > "$DATA_DIR/install_path"

PYTHON_BIN=""
for candidate in \
  /opt/homebrew/bin/python3.12 \
  /opt/homebrew/bin/python3.13 \
  /opt/homebrew/bin/python3.14 \
  python3.12 python3.13 python3.14 python3.11 python3; do
  if command -v "$candidate" >/dev/null 2>&1; then
    if "$candidate" - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 11) else 1)
PY
    then
      PYTHON_BIN="$candidate"
      break
    fi
  fi
done

if [[ -z "$PYTHON_BIN" ]]; then
  echo "Python 3.11 or newer was not found."
  if command -v brew >/dev/null 2>&1; then
    echo "Installing Python 3.12 with Homebrew..."
    brew install python@3.12
    PYTHON_BIN="/opt/homebrew/bin/python3.12"
  else
    echo "Homebrew is also missing. Install Python 3.12 from python.org, then run this file again."
    read -r -p "Press Return to close..."
    exit 1
  fi
fi

echo "Using $($PYTHON_BIN --version)"

if [[ "$JARVIS_VERIFICATION_BUILD" == "1" ]]; then
  echo "Verification build: skipping Python environment installation."
else
  if [[ ! -d .venv ]]; then
    echo "Creating Jarvis's private Python environment..."
    "$PYTHON_BIN" -m venv .venv
  fi

  echo "Installing Jarvis's pinned Python components..."
  .venv/bin/python -m pip install --disable-pip-version-check \
    --constraint "$ROOT/constraints.txt" -e "$ROOT"
fi

if [[ "$JARVIS_VERIFICATION_BUILD" == "1" \
      || "${JARVIS_SKIP_MODEL_DOWNLOADS:-0}" == "1" ]]; then
  echo "Skipping optional model downloads (verification build)."
else
  LOCAL_MODEL="$JARVIS_ROOT/Models/Qwen3.5-4B-OptiQ-4bit/model.safetensors"
  LARGE_LOCAL_MODEL_INDEX="$JARVIS_ROOT/Models/Qwen3.5-9B-4bit/model.safetensors.index.json"
  if [[ ! -f "$LOCAL_MODEL" || ! -f "$LARGE_LOCAL_MODEL_INDEX" ]]; then
    echo "Installing Jarvis's fast and multi-step local navigation models..."
    JARVIS_ROOT="$JARVIS_ROOT" "$ROOT/install_local_ai.command"
  fi

  OWNER_VOICE_MODEL="$JARVIS_ROOT/Models/OwnerVoice/wespeaker_v2.mlmodelc/weights/weight.bin"
  if [[ ! -f "$OWNER_VOICE_MODEL" ]]; then
    echo "Installing Jarvis's compact owner-voice model..."
    JARVIS_ROOT="$JARVIS_ROOT" "$ROOT/install_owner_voice.command"
  fi

  JARVIS_VOICE_MODEL="$JARVIS_ROOT/Models/JarvisVoice/Qwen3-TTS-12Hz-0.6B-Base-8bit/model.safetensors"
  JARVIS_VOICE_TOKENIZER="$JARVIS_ROOT/Models/JarvisVoice/Qwen3-TTS-12Hz-0.6B-Base-8bit/speech_tokenizer/model.safetensors"
  JARVIS_VOICE_REFERENCE="$JARVIS_ROOT/Models/JarvisVoice/OwnerProfile/reference.wav"
  JARVIS_VOICE_PROFILE="$JARVIS_ROOT/Models/JarvisVoice/OwnerProfile/profile-version"
  JARVIS_VOICE_PRESET="$JARVIS_ROOT/Models/JarvisVoice/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit/model.safetensors"
  JARVIS_VOICE_FALLBACK="$JARVIS_ROOT/Models/JarvisVoice/Kokoro-82M-bf16/kokoro-v1_0.safetensors"
  if [[ ! -f "$JARVIS_VOICE_MODEL" || ! -f "$JARVIS_VOICE_TOKENIZER" \
        || ! -f "$JARVIS_VOICE_REFERENCE" || ! -f "$JARVIS_VOICE_PRESET" \
        || ! -f "$JARVIS_VOICE_FALLBACK" || ! -f "$JARVIS_VOICE_PROFILE" \
        || "$(<"$JARVIS_VOICE_PROFILE")" != "original-cinematic-en-gb-v3" ]]; then
    echo "Installing Jarvis's local cinematic voice..."
    JARVIS_ROOT="$JARVIS_ROOT" "$ROOT/install_jarvis_voice.command"
  fi
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Apple's Command Line Tools are required."
  echo "macOS will open the installer now. Run bootstrap.command again after it finishes."
  xcode-select --install || true
  read -r -p "Press Return to close..."
  exit 1
fi

mkdir -p build

# Always pair Swift with the active Command Line Tools SDK. Hard-coding an older
# SDK breaks as soon as Apple updates the compiler while leaving legacy SDKs installed.
ACTIVE_MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
SWIFT_SDK_ARGS=(
  -sdk "$ACTIVE_MACOS_SDK"
  -target arm64-apple-macos14.0
)

# macOS beta point updates can briefly ship a Swift driver one patch newer
# than the textual Swift standard-library interface in the active SDK. Use the
# SDK's declared interface version only for that exact mismatch so rebuilds do
# not fail while Command Line Tools finishes updating.
SDK_SWIFT_INTERFACE="$(find "$ACTIVE_MACOS_SDK/usr/lib/swift/Swift.swiftmodule" \
  -name '*-apple-macos.swiftinterface' -print -quit 2>/dev/null || true)"
SDK_SWIFT_VERSION=""
if [[ -n "$SDK_SWIFT_INTERFACE" ]]; then
  SDK_SWIFT_VERSION="$(sed -nE \
    's/^\/\/ swift-compiler-version: Apple Swift version ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' \
    "$SDK_SWIFT_INTERFACE" | head -n 1)"
fi
SWIFT_COMPILER_VERSION="$(swiftc --version | sed -nE \
  's/.*Apple Swift version ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n 1)"
if [[ -n "$SDK_SWIFT_VERSION" \
      && -n "$SWIFT_COMPILER_VERSION" \
      && "$SDK_SWIFT_VERSION" != "$SWIFT_COMPILER_VERSION" ]]; then
  SWIFT_SDK_ARGS+=(
    -Xfrontend -interface-compiler-version
    -Xfrontend "$SDK_SWIFT_VERSION"
  )
fi

FOUNDATION_SWIFT_ARGS=(
  -sdk "$ACTIVE_MACOS_SDK"
  -target arm64-apple-macos26.0
)
if [[ -n "$SDK_SWIFT_VERSION" \
      && -n "$SWIFT_COMPILER_VERSION" \
      && "$SDK_SWIFT_VERSION" != "$SWIFT_COMPILER_VERSION" ]]; then
  FOUNDATION_SWIFT_ARGS+=(
    -Xfrontend -interface-compiler-version
    -Xfrontend "$SDK_SWIFT_VERSION"
  )
fi

echo "Building the native Mac control helper..."
swiftc native/JarvisNative.swift \
  "${SWIFT_SDK_ARGS[@]}" \
  -O \
  -o build/jarvis-native \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Vision \
  -framework Speech \
  -framework AVFoundation \
  -Xlinker -sectcreate \
  -Xlinker __TEXT \
  -Xlinker __info_plist \
  -Xlinker "$ROOT/native/NativeInfo.plist"
codesign --force --sign - build/jarvis-native >/dev/null
codesign --verify --strict build/jarvis-native

echo "Building the Apple on-device planning helper..."
swiftc native/JarvisFoundationPlanner.swift \
  "${FOUNDATION_SWIFT_ARGS[@]}" \
  -parse-as-library \
  -O \
  -o build/jarvis-foundation-planner \
  -framework FoundationModels
codesign --force --sign - build/jarvis-foundation-planner >/dev/null
codesign --verify --strict build/jarvis-foundation-planner

echo "Building the private Calendar, Reminders, and Contacts helper..."
swiftc native/JarvisPersonalData.swift \
  "${SWIFT_SDK_ARGS[@]}" \
  -parse-as-library \
  -O \
  -o build/jarvis-personal-data \
  -framework Contacts \
  -framework EventKit \
  -Xlinker -sectcreate \
  -Xlinker __TEXT \
  -Xlinker __info_plist \
  -Xlinker "$ROOT/native/PersonalInfo.plist"
codesign --force --sign - build/jarvis-personal-data >/dev/null
codesign --verify --strict build/jarvis-personal-data

echo "Building the native Keychain helper..."
swiftc native/JarvisKeychain.swift \
  "${SWIFT_SDK_ARGS[@]}" \
  -parse-as-library \
  -O \
  -o build/jarvis-keychain \
  -framework Security \
  -framework LocalAuthentication
codesign --force --sign - build/jarvis-keychain >/dev/null
codesign --verify --strict build/jarvis-keychain

echo "Building the local owner-voice verifier..."
swiftc native/JarvisVoiceprint.swift \
  "${SWIFT_SDK_ARGS[@]}" \
  -parse-as-library \
  -O \
  -o build/jarvis-voiceprint \
  -framework AVFoundation \
  -framework CoreML
codesign --force --sign - build/jarvis-voiceprint >/dev/null
codesign --verify --strict build/jarvis-voiceprint

echo "Building the Jarvis menu-bar application..."
# Swift accepts top-level executable code in a multi-file target only when the
# entry source is named main.swift. Stage the canonical source without creating
# a second editable implementation copy.
cp native/JarvisMenuBar.swift build/main.swift
swiftc build/main.swift native/JarvisIntents.swift native/JarvisVoiceprint.swift \
  "${SWIFT_SDK_ARGS[@]}" \
  -D JARVIS_APP \
  -module-name Jarvis \
  -O \
  -o build/Jarvis \
  -framework AppKit \
  -framework AppIntents \
  -framework ApplicationServices \
  -framework AVFoundation \
  -framework Carbon \
  -framework CoreAudio \
  -framework CoreGraphics \
  -framework CoreML \
  -framework LocalAuthentication \
  -framework QuartzCore \
  -framework ScreenCaptureKit \
  -framework ServiceManagement \
  -framework Speech
APP_BUILD="$ROOT/build/Jarvis.app"
rm -rf "$APP_BUILD"
mkdir -p "$APP_BUILD/Contents/MacOS" "$APP_BUILD/Contents/Resources"
cp build/Jarvis "$APP_BUILD/Contents/MacOS/Jarvis"
cp native/MenuInfo.plist "$APP_BUILD/Contents/Info.plist"
cp THIRD_PARTY_NOTICES.md "$APP_BUILD/Contents/Resources/THIRD_PARTY_NOTICES.md"

echo "Extracting Siri, Shortcuts, and Spotlight action metadata..."
# Const-value output is per Swift frontend job. Generate it from the intents
# source in one dedicated module compile so another app source cannot overwrite
# the metadata with an empty array during a multi-file executable build.
swiftc "$ROOT/native/JarvisIntents.swift" \
  "${SWIFT_SDK_ARGS[@]}" \
  -parse-as-library \
  -emit-module \
  -module-name Jarvis \
  -emit-module-path "$ROOT/build/JarvisAppIntents.swiftmodule" \
  -Xfrontend -emit-const-values-path \
  -Xfrontend "$ROOT/build/JarvisAppIntents.swiftconstvalues" \
  -Xfrontend -const-gather-protocols-file \
  -Xfrontend "$ROOT/native/AppIntentsProtocols.json" \
  -O \
  -framework AppIntents
XCODE_BUILD_VERSION="$(xcodebuild -version | sed -nE \
  's/^Build version (.+)$/\1/p' | head -n 1)"
APP_INTENTS_SOURCES_LIST="$ROOT/build/AppIntentsSources.list"
APP_INTENTS_CONST_VALUES_LIST="$ROOT/build/AppIntentsConstValues.list"
printf '%s\n' "$ROOT/native/JarvisIntents.swift" > "$APP_INTENTS_SOURCES_LIST"
printf '%s\n' "$ROOT/build/JarvisAppIntents.swiftconstvalues" > \
  "$APP_INTENTS_CONST_VALUES_LIST"
xcrun appintentsmetadataprocessor \
  --output "$APP_BUILD/Contents/Resources" \
  --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
  --module-name Jarvis \
  --sdk-root "$ACTIVE_MACOS_SDK" \
  --xcode-version "$XCODE_BUILD_VERSION" \
  --platform-family macOS \
  --deployment-target 14.0 \
  --target-triple arm64-apple-macos14.0 \
  --source-file-list "$APP_INTENTS_SOURCES_LIST" \
  --swift-const-vals-list "$APP_INTENTS_CONST_VALUES_LIST" \
  --force \
  --no-app-shortcuts-localization

if [[ ! -s "$APP_BUILD/Contents/Resources/Metadata.appintents/extract.actionsdata" ]]; then
  echo "Jarvis App Intents metadata extraction failed." >&2
  exit 1
fi

if command -v iconutil >/dev/null 2>&1; then
  iconutil -c icns assets/Jarvis.iconset -o "$APP_BUILD/Contents/Resources/Jarvis.icns" || true
fi

codesign --force --deep --sign - --options runtime \
  --entitlements "$ROOT/native/Jarvis.entitlements" \
  --requirements "$CODESIGN_REQUIREMENT" \
  "$APP_BUILD" >/dev/null
codesign --verify --deep --strict "$APP_BUILD"
INSTALLED_APP="$APP_DIR/Jarvis.app"
rm -rf "$INSTALLED_APP"
cp -R "$APP_BUILD" "$INSTALLED_APP"
codesign --verify --deep --strict "$INSTALLED_APP"
cp build/jarvis-native "$DATA_DIR/bin/jarvis-native"
cp build/jarvis-foundation-planner "$DATA_DIR/bin/jarvis-foundation-planner"
cp build/jarvis-personal-data "$DATA_DIR/bin/jarvis-personal-data"
cp build/jarvis-keychain "$DATA_DIR/bin/jarvis-keychain"
cp build/jarvis-voiceprint "$DATA_DIR/bin/jarvis-voiceprint"
chmod 700 \
  "$DATA_DIR/bin/jarvis-native" \
  "$DATA_DIR/bin/jarvis-foundation-planner" \
  "$DATA_DIR/bin/jarvis-personal-data" \
  "$DATA_DIR/bin/jarvis-keychain" \
  "$DATA_DIR/bin/jarvis-voiceprint"

chmod -R go-rwx "$JARVIS_ROOT"

chmod +x ./*.command 2>/dev/null || true

printf '\nRunning verified core tests...\n'
if [[ "$JARVIS_VERIFICATION_BUILD" == "1" ]]; then
  echo "Verification build: automated tests run separately with scripts/verify.sh."
else
  TEST_DATA="${TMPDIR:-/tmp}/jarvis-bootstrap-tests-$$"
  trap 'rm -rf "$TEST_DATA"' EXIT
  PYTHONDONTWRITEBYTECODE=1 JARVIS_ROOT="$TEST_DATA/root" JARVIS_DATA_DIR="$TEST_DATA" \
    .venv/bin/python -m unittest discover -s tests -v
fi

printf '\nInstallation complete.\n\n'
printf 'Jarvis.app was installed in: %s\n' "$INSTALLED_APP"
printf 'Open it from Finder → your home folder → Jarvis → App.\n'
printf 'The first screen, voice, and control actions will ask for macOS permissions.\n\n'
if [[ "${JARVIS_NONINTERACTIVE:-0}" != "1" ]]; then
  open "$APP_DIR" || true
  read -r -p "Press Return to close..."
fi
