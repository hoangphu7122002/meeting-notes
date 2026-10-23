#!/usr/bin/env bash
# Per-account step for a shared install (scripts/install.sh --shared installs this as
# <shared root>/bin/meeting-notes-user-setup). Run it once in every account that uses MeetingNotes, logged in
# as that account. No admin rights, no downloads; it only touches this account's files.
#
# Usage: meeting-notes-user-setup [--dry-run] [--open]
#   --dry-run  print what it would do; change nothing
#   --open     open the app at the end (then grant Microphone and Screen & System Audio Recording)
#
# Creates ~/MeetingNotes and ~/.config/meeting-notes (mode 700), checks the shared pipeline and models with
# `meeting-notes doctor --offline`, checks that a local Ollama answers, and prints the permission steps.
# Recordings, config.toml, the optional HF token (~/.config/meeting-notes/.env), logs and macOS permissions stay
# in this account. Env (tests): MN_SHARED_ROOT overrides the shared root (default: this script's ../).
set -euo pipefail

DRY_RUN=0 OPEN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --open) OPEN=1 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg (see --help)" >&2; exit 64 ;;
  esac
done

ROOT="${MN_SHARED_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
MARKER="$ROOT/shared-install.json"
CLI="$ROOT/pipeline/.venv/bin/meeting-notes"
OLLAMA_API="http://127.0.0.1:11434/api/version"

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
run() {
  printf '+ %s\n' "$*"
  [[ "$DRY_RUN" -eq 1 ]] || "$@"
}

[[ -r "$MARKER" ]] || die "no shared install at $ROOT (missing $MARKER). The admin account runs: scripts/install.sh --shared"
[[ -x "$CLI" ]] || die "the shared pipeline is not usable from $(id -un) ($CLI). Ask the installing account to re-run scripts/install.sh --shared"
APP="$(plutil -extract app raw -o - "$MARKER" 2>/dev/null || true)"
[[ -n "$APP" ]] || APP=/Applications/MeetingNotes.app

say "MeetingNotes for $(id -un) (shared install: $ROOT)"
run mkdir -p "$HOME/MeetingNotes" "$HOME/.config/meeting-notes"
run chmod 700 "$HOME/.config/meeting-notes"
if [[ -d "$HOME/Applications/MeetingNotes.app" ]]; then
  echo "note: $HOME/Applications/MeetingNotes.app is an old per-user copy; remove it so macOS opens $APP:"
  echo "      mv \"$HOME/Applications/MeetingNotes.app\" ~/.Trash/"
fi

say "Check (pipeline, models, Ollama)"
run "$CLI" doctor --offline || true
if ! curl -sf --max-time 2 "$OLLAMA_API" >/dev/null 2>&1; then
  cat <<EOF
note: no Ollama answers on 127.0.0.1:11434, so notes get no summary until one does (Reprocess then adds it).
      Usually the installing account's Ollama serves every account while it is logged in (fast user switching).
      To run one in this account instead, see docs/research/one-click-install.md "Shared install" > Ollama.
EOF
fi

[[ "$OPEN" -eq 1 ]] && run open "$APP"

cat <<EOF

Done$([[ "$DRY_RUN" -eq 1 ]] && echo " (dry run: nothing was changed)"). In this account:
  1. Open the app:  open "$APP"
  2. Allow Microphone when asked.
  3. System Settings > Privacy & Security > Screen & System Audio Recording: enable MeetingNotes, then relaunch it.
  4. Optional: Settings > Launch at Login. Optional: HF_TOKEN=... in ~/.config/meeting-notes/.env (chmod 600).
Recordings go to ~/MeetingNotes in this account only.
EOF
