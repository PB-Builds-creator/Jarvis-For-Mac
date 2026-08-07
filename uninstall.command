#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

printf '\nThis removes the Jarvis app.\n'
read -r -p "Also delete Jarvis memory, settings, screenshots, and logs? Type DELETE to confirm, or press Return to keep them: " ANSWER

rm -rf "$HOME/Jarvis/App/Jarvis.app"

if [[ "$ANSWER" == "DELETE" ]]; then
  rm -rf "$HOME/Jarvis/Data"
  if [[ -L "$HOME/.jarvis" ]]; then rm "$HOME/.jarvis"; fi
  echo "Jarvis and its data were removed."
else
  echo "Jarvis.app was removed. Your Jarvis/Data folder was kept."
fi
read -r -p "Press Return to close..."
