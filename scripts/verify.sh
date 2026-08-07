#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -n "${JARVIS_PYTHON:-}" && -x "$JARVIS_PYTHON" ]]; then
  PYTHON="$JARVIS_PYTHON"
elif [[ -x "$ROOT/.venv/bin/python" ]]; then
  PYTHON="$ROOT/.venv/bin/python"
elif command -v python3 >/dev/null 2>&1; then
  PYTHON="$(command -v python3)"
else
  echo "Python 3.11 or newer is required." >&2
  exit 1
fi

if ! "$PYTHON" -c 'import misaki, numpy, scipy' >/dev/null 2>&1; then
  echo "Test dependencies are missing. Create .venv and install the project as shown in README.md." >&2
  exit 1
fi

bash -n bootstrap.command install_jarvis_voice.command install_owner_voice.command \
  run_jarvis.command uninstall.command scripts/secret-scan.sh scripts/verify.sh
zsh -n install_local_ai.command repair_screen_capture.command
"$PYTHON" -m json.tool config.example.json >/dev/null
"$PYTHON" -m json.tool native/AppIntentsProtocols.json >/dev/null
if command -v plutil >/dev/null 2>&1; then
  plutil -lint native/MenuInfo.plist native/NativeInfo.plist \
    native/PersonalInfo.plist native/Jarvis.entitlements >/dev/null
fi

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/jarvis-verify.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

PYTHONDONTWRITEBYTECODE=1 \
PYTHONPATH="$ROOT" \
JARVIS_ROOT="$TEST_ROOT/root" \
JARVIS_DATA_DIR="$TEST_ROOT/data" \
"$PYTHON" -W error::ResourceWarning -m unittest discover -s tests -v

"$ROOT/scripts/secret-scan.sh"

if command -v swiftc >/dev/null 2>&1; then
  swiftc -frontend -parse native/JarvisMenuBar.swift
  swiftc -frontend -parse native/JarvisFoundationPlanner.swift
  swiftc -frontend -parse native/JarvisIntents.swift
  swiftc -frontend -parse native/JarvisKeychain.swift
  swiftc -frontend -parse native/JarvisNative.swift
  swiftc -frontend -parse native/JarvisPersonalData.swift
  swiftc -frontend -parse native/JarvisVoiceprint.swift
fi

echo "Jarvis source verification passed."
