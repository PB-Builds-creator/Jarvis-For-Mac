#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail=0

if rg -n --hidden \
  --glob '!.git/**' \
  --glob '!.venv/**' \
  --glob '!build/**' \
  --glob '!native/AppIntentsSources.list' \
  --glob '!native/AppIntentsConstValues.list' \
  --glob '!scripts/secret-scan.sh' \
  '(\/Users\/[A-Za-z0-9._-]+\/|g-p-[a-z0-9]+|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16})' .; then
  echo "Public scan found a private path, task identifier, private key, or token-like value." >&2
  fail=1
fi

if find . -type f \( \
  -name '*.db' -o -name '*.db-wal' -o -name '*.db-shm' -o \
  -name '*.wav' -o -name '*.aiff' -o -name '*.m4a' -o \
  -name '*.safetensors' -o -name '*.gguf' -o -name '*.jbackup' \
\) -not -path './.git/*' -not -path './.venv/*' -not -path './build/*' | grep -q .; then
  echo "Public scan found runtime data, audio, model weights, or backup artifacts." >&2
  fail=1
fi

if find . -type f -size +20M -not -path './.git/*' -not -path './.venv/*' -not -path './build/*' | grep -q .; then
  echo "Public scan found a file larger than 20 MB; review it before publishing." >&2
  fail=1
fi

if command -v gitleaks >/dev/null 2>&1; then
  gitleaks detect --no-banner --no-git --source "$ROOT"
else
  echo "gitleaks not installed; built-in privacy and token-pattern scan completed."
fi

if [[ "$fail" != "0" ]]; then
  exit 1
fi

echo "Public privacy and secret scan passed."
