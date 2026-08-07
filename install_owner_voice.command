#!/bin/bash
set -euo pipefail
umask 077

JARVIS_ROOT="${JARVIS_ROOT:-$HOME/Jarvis}"
DESTINATION="$JARVIS_ROOT/Models/OwnerVoice/wespeaker_v2.mlmodelc"
REVISION="1ed7a662fdc7109e36d822db793ee6eebdaf8594"
BASE_URL="https://huggingface.co/FluidInference/speaker-diarization-coreml/resolve/$REVISION/wespeaker_v2.mlmodelc"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/jarvis-owner-voice.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT
MODEL_ROOT="$TEMP_ROOT/wespeaker_v2.mlmodelc"

mkdir -p "$MODEL_ROOT/analytics" "$MODEL_ROOT/weights"

download_verified() {
  local relative_path="$1"
  local expected_sha="$2"
  local destination="$MODEL_ROOT/$relative_path"
  curl --fail --location --silent --show-error \
    "$BASE_URL/$relative_path" \
    --output "$destination"
  local actual_sha
  actual_sha="$(shasum -a 256 "$destination" | awk '{print $1}')"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    echo "Owner-voice model checksum failed for $relative_path." >&2
    exit 1
  fi
}

download_verified "analytics/coremldata.bin" \
  "d2b1fcde6121aea3ff0e14c1dc50d09dacb0314a2e89156353c31804230a422f"
download_verified "coremldata.bin" \
  "6feb2472a71fa9d8a84020c85206138a4f6261c565c9884bf518d59dd5838da7"
download_verified "metadata.json" \
  "ddc4858b4051254098015cd0b97080149839d697faf7b036f933190e70b26758"
download_verified "model.mil" \
  "2850f775d6ba659f01f616fed77ce6a45a25de3eb7e4bf3a4b07b658be4e13dd"
download_verified "weights/weight.bin" \
  "34004f6798d35cad7071e2fdc67e63faaa782f53697e1cb49bcb452cf81ae151"

mkdir -p "$(dirname "$DESTINATION")"
rm -rf "$DESTINATION"
mv "$MODEL_ROOT" "$DESTINATION"
chmod -R go-rwx "$JARVIS_ROOT/Models/OwnerVoice"

cat <<'EOF'
Installed Jarvis Owner Voice:
- WeSpeaker v2 Core ML int8 speaker embedding model
- Runs locally using CPU and Apple Neural Engine
- Model repository license: CC BY 4.0
- Source: FluidInference/speaker-diarization-coreml
EOF
