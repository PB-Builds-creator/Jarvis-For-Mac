#!/bin/bash
set -euo pipefail
umask 077

JARVIS_ROOT="${JARVIS_ROOT:-$HOME/Jarvis}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
VOICE_ROOT="$JARVIS_ROOT/Models/JarvisVoice"
DESTINATION="$JARVIS_ROOT/Models/JarvisVoice/Kokoro-82M-bf16"
REVISION="a71e4d38b236d968966a2002c4c895dbd12b1c3c"
BASE_URL="https://huggingface.co/mlx-community/Kokoro-82M-bf16/resolve/$REVISION"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/jarvis-neural-voice.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT
MODEL_ROOT="$TEMP_ROOT/Kokoro-82M-bf16"

if [[ ! -x "$ROOT/.venv/bin/python" ]]; then
  echo "Jarvis's private Python environment is missing. Run bootstrap.command first." >&2
  exit 1
fi

echo "Installing Jarvis's original cinematic British Qwen3 voice..."
"$ROOT/.venv/bin/python" - "$VOICE_ROOT" <<'PY'
import contextlib
import io
from pathlib import Path
import shutil
import subprocess
import sys
import wave

from huggingface_hub import snapshot_download
import mlx.core as mx
import numpy as np
from mlx_audio.tts.utils import load_model

root = Path(sys.argv[1])
models = (
    (
        "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit",
        "50f45ef0047cde7e84c2ef04326acb8ada2436a7",
    ),
    (
        "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-5bit",
        "6e936cfb98d95b707bd1f85351874a377230fe83",
    ),
    (
        "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit",
        "f35faf19b0cc2160865af64ecf0f22f83d335135",
    ),
)
for repository, revision in models:
    snapshot_download(
        repo_id=repository,
        revision=revision,
        local_dir=root / repository.rsplit("/", 1)[-1],
    )

reference_dir = root / "OwnerProfile"
reference_dir.mkdir(parents=True, exist_ok=True)
reference_path = reference_dir / "reference.wav"
runtime_reference_path = reference_dir / "reference-runtime.wav"
profile_path = reference_dir / "profile-version"
profile_version = "original-cinematic-en-gb-v3"
if (
    not reference_path.is_file()
    or not runtime_reference_path.is_file()
    or not profile_path.is_file()
    or profile_path.read_text(encoding="utf-8").strip() != profile_version
):
    text = (
        "Good evening. The laboratory and armour systems are ready. After "
        "reviewing the data, I rather think we should wait. Everything remains under "
        "control, sir."
    )
    instruction = (
        "Create an entirely original cinematic artificial-intelligence voice. A native "
        "English man in his early forties speaking unmistakable modern Received "
        "Pronunciation: clipped British consonants, non-rhotic final R sounds, broad "
        "Southern English vowels in after, rather, last, chance, and chart, and no "
        "American vowels. His voice is a smooth low-mid baritone with a polished dulcet "
        "tone, precise diction, controlled deadpan delivery, restrained warmth, quiet "
        "competence, and the faintest dry wit. He is subtly amused but never animated; "
        "sentence endings settle downward. Close, clean studio microphone with minimal "
        "breath. Do not sound elderly, theatrical, gravelly, like a newsreader, or like "
        "an existing actor or character."
    )
    if reference_path.is_file():
        shutil.copy2(reference_path, reference_dir / "reference-natural-british-backup.wav")
    try:
        mx.random.seed(20260806)
        muted = io.StringIO()
        with contextlib.redirect_stdout(muted), contextlib.redirect_stderr(muted):
            model = load_model(
                root / "Qwen3-TTS-12Hz-1.7B-VoiceDesign-5bit",
                lazy=False,
            )
            parts = [
                np.asarray(result.audio).reshape(-1)
                for result in model.generate(
                    text,
                    instruct=instruction,
                    lang_code="english",
                    temperature=0.66,
                    top_k=30,
                    top_p=0.88,
                    repetition_penalty=1.08,
                    max_tokens=4096,
                    verbose=False,
                )
            ]
        if not parts:
            raise RuntimeError("The cinematic voice generated no reference audio.")
        audio = np.clip(np.concatenate(parts), -1.0, 1.0)
        pcm = (audio * 32767.0).astype("<i2").tobytes()
        with wave.open(str(reference_path), "wb") as output:
            output.setnchannels(1)
            output.setsampwidth(2)
            output.setframerate(24_000)
            output.writeframes(pcm)
        mx.clear_cache()
    except Exception:
        # A deterministic native English (UK) source keeps first-time setup
        # functional even if the optional design model cannot initialise.
        source_path = reference_dir / "reference-source.aiff"
        subprocess.run(
            [
                "/usr/bin/say", "-v", "Daniel", "-r", "158", "-o",
                str(source_path), text,
            ],
            check=True,
        )
        subprocess.run(
            [
                "/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@24000",
                str(source_path), str(reference_path),
            ],
            check=True,
        )
        source_path.unlink(missing_ok=True)
    with wave.open(str(reference_path), "rb") as source:
        pcm = source.readframes(min(source.getnframes(), int(2.55 * 24_000)))
    with wave.open(str(runtime_reference_path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(24_000)
        output.writeframes(pcm)
    for path in (reference_path, runtime_reference_path):
        path.chmod(0o600)
    profile_path.write_text(profile_version + "\n", encoding="utf-8")
    profile_path.chmod(0o600)
PY

mkdir -p "$MODEL_ROOT/voices"

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
    echo "Jarvis voice checksum failed for $relative_path." >&2
    exit 1
  fi
}

download_verified "config.json" \
  "5abb01e2403b072bf03d04fde160443e209d7a0dad49a423be15196b9b43c17f"
download_verified "kokoro-v1_0.safetensors" \
  "4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8"
download_verified "voices/bm_george.safetensors" \
  "a3d9b8995cbbe5536f954b6be2a0f1f312f077118ba0d4d2178fc41dc8306672"

mkdir -p "$(dirname "$DESTINATION")"
rm -rf "$DESTINATION"
mv "$MODEL_ROOT" "$DESTINATION"
chmod -R go-rwx "$JARVIS_ROOT/Models/JarvisVoice"

cat <<'EOF'
Installed Jarvis Cinematic Voice:
- Original clipped British cinematic voice designed and reproduced locally with Qwen3-TTS
- Qwen3-TTS 0.6B Base 8-bit for fast, consistent runtime speech
- Qwen3-TTS 1.7B CustomVoice 4-bit as the first fallback
- Kokoro-82M BF16 British voice as the lightweight fallback
- Runs locally on Apple Silicon and unloads after each spoken response
- Apache-2.0 model license
- Uses an original wise-butler style, not an actor or character voice clone
EOF
