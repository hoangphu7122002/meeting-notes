#!/usr/bin/env bash
# One-shot setup: dependencies, Python environment, models, and the menu bar app.
# Safe to re-run. Usage: scripts/install.sh [--skip-models]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKIP_MODELS=0
[[ "${1:-}" == "--skip-models" ]] && SKIP_MODELS=1

command -v brew >/dev/null || { echo "Homebrew is required: https://brew.sh" >&2; exit 1; }
command -v uv >/dev/null || [[ -x "$HOME/.local/bin/uv" ]] || brew install uv

echo "==> Homebrew packages (ffmpeg, ollama)"
for pkg in ffmpeg ollama; do brew list --formula "$pkg" >/dev/null 2>&1 || brew install "$pkg"; done
brew services start ollama >/dev/null

echo "==> Python pipeline environment"
UV="$(command -v uv || echo "$HOME/.local/bin/uv")"
"$UV" sync --project "$ROOT/pipeline"

if [[ ! -f "$ROOT/.env" ]]; then
  echo "note: no $ROOT/.env with HF_TOKEN; diarization will use the ungated fallback (see README)."
fi

if [[ "$SKIP_MODELS" == 0 ]]; then
  echo "==> Models (whisper, speaker embeddings, Ollama)"
  for _ in $(seq 1 30); do curl -sf http://127.0.0.1:11434/api/version >/dev/null && break; sleep 1; done
  "$UV" run --project "$ROOT/pipeline" meeting-notes setup
fi

echo "==> Menu bar app"
"$ROOT/scripts/build-app.sh"

"$UV" run --project "$ROOT/pipeline" meeting-notes doctor
echo "Done. Open ~/Applications/MeetingNotes.app"
