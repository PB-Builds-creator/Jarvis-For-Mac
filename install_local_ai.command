#!/bin/zsh
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")" && pwd)"
JARVIS_ROOT="${JARVIS_ROOT:-$HOME/Jarvis}"
MODEL_DIR="$JARVIS_ROOT/Models/Qwen3.5-4B-OptiQ-4bit"
MODEL_REPO="mlx-community/Qwen3.5-4B-OptiQ-4bit"
MODEL_REVISION="6cb5bdfd0bf15f484881fb9f1ab6d7c840fddde9"
LARGE_MODEL_DIR="$JARVIS_ROOT/Models/Qwen3.5-9B-4bit"
LARGE_MODEL_REPO="mlx-community/Qwen3.5-9B-4bit"
LARGE_MODEL_REVISION="8b2b98c00a6b4d291155e4890773ca8f769aee53"

if [[ ! -x "$ROOT/.venv/bin/python" ]]; then
  echo "Jarvis's private Python environment is missing. Run bootstrap.command first."
  exit 1
fi

echo "Installing Jarvis's pinned local-AI runtime..."
"$ROOT/.venv/bin/python" -m pip install --disable-pip-version-check \
  --constraint "$ROOT/constraints.txt" -e "$ROOT"

if [[ -f "$MODEL_DIR/model.safetensors" ]]; then
  echo "Jarvis's fast 4B local model is already installed."
else
  echo "Downloading the local Qwen3.5 4B model into Home → Jarvis → Models..."
  mkdir -p "$MODEL_DIR"
  "$ROOT/.venv/bin/hf" download "$MODEL_REPO" \
    --revision "$MODEL_REVISION" --local-dir "$MODEL_DIR"
fi

if [[ -f "$LARGE_MODEL_DIR/model.safetensors.index.json" ]]; then
  echo "Jarvis's multi-step 9B local model is already installed."
else
  echo "Downloading the local Qwen3.5 9B model into Home → Jarvis → Models..."
  mkdir -p "$LARGE_MODEL_DIR"
  "$ROOT/.venv/bin/hf" download "$LARGE_MODEL_REPO" \
    --revision "$LARGE_MODEL_REVISION" --local-dir "$LARGE_MODEL_DIR"
fi

"$ROOT/.venv/bin/python" -c \
  'from jarvis.local_model import ENGINE; status = ENGINE.status(); assert status["small_installed"] and status["large_installed"]; print("4B + 9B local AI is installed and ready.")'
