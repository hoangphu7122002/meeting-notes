#!/usr/bin/env bash
# One-pass install, idempotent and safe to re-run: prerequisites, Python environment, models, menu bar app.
# No Hugging Face account needed: the default FluidAudio diarizer uses ungated weights. HF_TOKEN in .env is
# optional (only the pyannote fallback uses it).
#
# Usage: scripts/install.sh [--dry-run] [--yes] [--force] [--skip-models] [--shared]
#   --dry-run      check and print the plan and every command; change nothing
#   --yes          do not ask before installing missing tools or quitting an idle MeetingNotes
#   --force        reinstall the app even while MeetingNotes records (quits it); never needed when it is idle
#   --skip-models  skip model downloads (whisper, speaker embeddings, FluidAudio, Ollama summary model)
#   --shared       one install for every account on this Mac: app in /Applications, pipeline + models in
#                  /Users/Shared/MeetingNotes (read-only for other accounts); scripts/install-shared.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN=0 YES=0 FORCE=0 SKIP_MODELS=0 SHARED=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y) YES=1 ;;
    --force) FORCE=1 ;;
    --skip-models) SKIP_MODELS=1 ;;
    --shared) SHARED=1 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg (see --help)" >&2; exit 64 ;;
  esac
done

# shellcheck source=scripts/app-state.sh
source "$ROOT/scripts/app-state.sh"

APP="$HOME/Applications/MeetingNotes.app"
if [[ "$SHARED" -eq 1 ]]; then
  # shellcheck source=scripts/install-shared.sh
  source "$ROOT/scripts/install-shared.sh"
  shared_init  # APP = /Applications/MeetingNotes.app (or the shared root when not an admin)
fi
OLLAMA_API="http://127.0.0.1:11434/api/version"
HOMEBREW_INSTALLER="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"  # official
INTERACTIVE=0
[[ -t 0 && -t 1 ]] && INTERACTIVE=1

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
# Print a command, then run it unless --dry-run.
run() {
  printf '+ %s\n' "$*"
  [[ "$DRY_RUN" -eq 1 ]] || "$@"
}
ask() {  # ask "question": yes with --yes; no when not interactive
  [[ "$YES" -eq 1 ]] && return 0
  [[ "$INTERACTIVE" -eq 1 ]] || return 1
  local reply
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy] ]]
}
have() { command -v "$1" >/dev/null 2>&1; }
brew_bin() {
  if have brew; then command -v brew
  elif [[ -x /opt/homebrew/bin/brew ]]; then echo /opt/homebrew/bin/brew
  elif [[ -x /usr/local/bin/brew ]]; then echo /usr/local/bin/brew
  fi
}
uv_bin() {
  if have uv; then command -v uv
  elif [[ -x "$HOME/.local/bin/uv" ]]; then echo "$HOME/.local/bin/uv"
  fi
}
ollama_app() { [[ -d /Applications/Ollama.app || -d "$HOME/Applications/Ollama.app" ]]; }
ollama_up() { curl -sf --max-time 2 "$OLLAMA_API" >/dev/null 2>&1; }

# ---------------------------------------------------------------- checks (read-only)

say "Checking this Mac"
[[ "$(uname -s)" == Darwin ]] || die "macOS only"
[[ "$(uname -m)" == arm64 ]] || echo "warning: Apple Silicon is required for the MLX and Neural Engine models" >&2
macos_major="$(sw_vers -productVersion | cut -d. -f1)"
[[ "$macos_major" -ge 14 ]] || die "macOS 14 or newer is required (found $(sw_vers -productVersion))"

[[ "$SHARED" -eq 1 ]] && shared_checks

# A running MeetingNotes is quit only when it is idle (and you agree), never while it records unless --force.
pids="$(mn_app_pids "$APP")"
if [[ -n "$pids" ]]; then
  activity="$(mn_app_activity)"
  if [[ "$activity" =~ ^(recording|unknown)$ && "$FORCE" -eq 0 ]]; then
    die "MeetingNotes is running and recording (or its state is unknown). Stop the recording and re-run, or pass --force."
  elif [[ "$FORCE" -eq 1 ]]; then
    echo "MeetingNotes is running ($activity); --force: it will be quit before the new build is installed."
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    echo "MeetingNotes is running ($activity); a real run asks before quitting it."
  else
    note=""
    [[ "$activity" == processing ]] && note=" Its notes job stops and can be resumed with Reprocess."
    ask "MeetingNotes is running ($activity).$note Quit it and reinstall?" \
      || die "MeetingNotes is running; quit it first, or re-run with --yes."
  fi
fi

missing_clt=0
xcode-select -p >/dev/null 2>&1 || missing_clt=1
BREW="$(brew_bin)"
UV="$(uv_bin)"
formulas=()
[[ -n "$UV" ]] || formulas+=(uv)
have ffmpeg || formulas+=(ffmpeg)
{ have ollama || ollama_app; } || formulas+=(ollama)

say "Plan"
[[ "$missing_clt" -eq 1 ]] && echo "  install  Xcode Command Line Tools (Apple's installer dialog; re-run this script afterwards)"
[[ -z "$BREW" ]] && echo "  install  Homebrew (official installer from $HOMEBREW_INSTALLER; asks for your password)"
[[ "${#formulas[@]}" -gt 0 ]] && echo "  install  brew: ${formulas[*]}"
ollama_up || echo "  start    Ollama (brew services, or Ollama.app)"
if [[ "$SHARED" -eq 1 ]]; then
  shared_plan
else
  echo "  sync     Python environment: uv sync in pipeline/ (~0.35 GB download on first run)"
  echo "  build    FluidAudio diarization helper (swift build -c release --product MeetingNotesDiarize)"
  if [[ "$SKIP_MODELS" -eq 0 ]]; then
    echo "  models   meeting-notes setup: whisper (~464 MB), speaker embeddings (27 MB), FluidAudio (~21 MB, no login),"
    echo "           Ollama summary model (config ollama_model, default qwen3:4b ~2.5 GB); already present = skipped"
  fi
  echo "  app      scripts/build-app.sh: build, sign and install $APP (with the diarization helper)"
fi
[[ -f "$ROOT/.env" ]] || echo "  note     no .env with HF_TOKEN: fine (optional, only for the pyannote fallback)"

if [[ "$DRY_RUN" -eq 0 && ( "$missing_clt" -eq 1 || -z "$BREW" || "${#formulas[@]}" -gt 0 ) && "$INTERACTIVE" -eq 1 ]]; then
  ask "Install the missing tools above?" || die "cancelled"
fi

# ---------------------------------------------------------------- prerequisites

if [[ "$missing_clt" -eq 1 ]]; then
  say "Xcode Command Line Tools"
  run xcode-select --install || true
  [[ "$DRY_RUN" -eq 1 ]] || die "finish the Command Line Tools installer, then re-run scripts/install.sh"
fi

if [[ -z "$BREW" ]]; then
  say "Homebrew (official installer)"
  # shellcheck disable=SC2016  # print the command literally
  printf '+ /bin/bash -c "$(curl -fsSL %s)"\n' "$HOMEBREW_INSTALLER"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    /bin/bash -c "$(curl -fsSL "$HOMEBREW_INSTALLER")"
    BREW="$(brew_bin)"
    [[ -n "$BREW" ]] || die "Homebrew did not install"
  else
    BREW=brew
  fi
fi
[[ "$DRY_RUN" -eq 1 ]] || eval "$("$BREW" shellenv)"

if [[ "${#formulas[@]}" -gt 0 ]]; then
  say "Homebrew packages"
  run "$BREW" install "${formulas[@]}"
fi
UV="$(uv_bin)"
UV="${UV:-uv}"

if ! ollama_up; then
  say "Starting Ollama"
  if ollama_app && ! "$BREW" list --formula ollama >/dev/null 2>&1; then
    run open -a Ollama
  else
    run "$BREW" services start ollama
  fi
  if [[ "$DRY_RUN" -eq 0 ]]; then
    for _ in $(seq 1 30); do ollama_up && break; sleep 1; done
    ollama_up || echo "warning: Ollama is not answering yet; the summary model is pulled on the next run" >&2
  fi
fi

# ---------------------------------------------------------------- environment, helper, models, app

if [[ "$SHARED" -eq 1 ]]; then
  shared_install
  shared_done
  exit 0
fi

say "Python pipeline environment"
run "$UV" sync --project "$ROOT/pipeline"

say "FluidAudio diarization helper"
run swift build -c release --package-path "$ROOT/app" --product MeetingNotesDiarize

if [[ "$SKIP_MODELS" -eq 0 ]]; then
  say "Models (already downloaded ones are skipped)"
  run "$UV" run --project "$ROOT/pipeline" meeting-notes setup
fi

say "Menu bar app"
build_args=()
[[ "$FORCE" -eq 1 ]] && build_args+=(--force)
run "$ROOT/scripts/build-app.sh" ${build_args[@]+"${build_args[@]}"}

say "Check"
run "$UV" run --project "$ROOT/pipeline" meeting-notes doctor || true

cat <<EOF

Done$([[ "$DRY_RUN" -eq 1 ]] && echo " (dry run: nothing was changed)"). Next steps:
  1. Open the app:  open "$APP"
  2. Allow Microphone when asked.
  3. System Settings > Privacy & Security > Screen & System Audio Recording: enable MeetingNotes, then relaunch it.
  4. Optional: Settings > Launch at Login. A Hugging Face token is not needed.
EOF
