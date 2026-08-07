#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
if [[ ! -x "$ROOT/.venv/bin/python" ]]; then
  echo "Jarvis is not installed yet. Run bootstrap.command first."
  read -r -p "Press Return to close..."
  exit 1
fi
"$ROOT/.venv/bin/python" -m jarvis dashboard
