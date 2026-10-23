# shellcheck shell=bash
# Sourced by scripts/install.sh for --shared: one install for every macOS account on this Mac.
#
#   /Applications/MeetingNotes.app          app (or $SHARED_ROOT/MeetingNotes.app when /Applications is not writable)
#   $SHARED_ROOT/pipeline/                  pipeline source + prebuilt .venv (uv-managed Python in python/)
#   $SHARED_ROOT/models/                    FluidAudio, Hugging Face hub cache (whisper, embeddings), whisperkit (captions)
#   $SHARED_ROOT/bin/                       uv, meeting-notes (CLI), meeting-notes-user-setup (per-account step)
#   $SHARED_ROOT/shared-install.json        marker read by the app (PipelineLocator) and the pipeline (config/install.py)
#
# Owned by the installing account, world-readable, never world-writable. Per account (never here): recordings
# (~/MeetingNotes), ~/.config/meeting-notes (config.toml, optional .env with HF_TOKEN), logs, caches, TCC
# permissions, Launch at Login. Never runs sudo: when admin rights would be needed it prints the command.
#
# Env (tests/advanced): MN_SHARED_ROOT (default /Users/Shared/MeetingNotes), MN_APPLICATIONS_DIR (default /Applications)

shared_init() {
  SHARED_ROOT="${MN_SHARED_ROOT:-/Users/Shared/MeetingNotes}"
  APPS_DIR="${MN_APPLICATIONS_DIR:-/Applications}"
  if [[ -d "$APPS_DIR" && -w "$APPS_DIR" ]]; then
    APP_DIR="$APPS_DIR"
    ADMIN_NOTE=""
  else
    APP_DIR="$SHARED_ROOT"
    ADMIN_NOTE="$APPS_DIR is not writable for $(id -un) (not an admin): the app goes to $APP_DIR/MeetingNotes.app."
  fi
  APP="$APP_DIR/MeetingNotes.app"
  LEGACY_APP="$HOME/Applications/MeetingNotes.app"
  SHARED_PIPELINE="$SHARED_ROOT/pipeline"
  SHARED_UV="$SHARED_ROOT/bin/uv"
  SHARED_CLI="$SHARED_ROOT/bin/meeting-notes"
  SHARED_HUB="$SHARED_ROOT/models/huggingface/hub"
  USER_ENV="$HOME/.config/meeting-notes/.env"
}

# Refuse a shared root another account could tamper with, a token file in it, or an install under a running session.
shared_checks() {
  local parent owner mode others
  parent="$(dirname "$SHARED_ROOT")"
  [[ -d "$parent" ]] || die "$parent does not exist"
  if [[ -e "$SHARED_ROOT" ]]; then
    [[ -d "$SHARED_ROOT" && ! -L "$SHARED_ROOT" ]] || die "$SHARED_ROOT exists but is not a directory"
    owner="$(stat -f %Su "$SHARED_ROOT")"
    mode="$(stat -f %Lp "$SHARED_ROOT")"
    if [[ "$owner" != "$(id -un)" || $(( 8#$mode & 8#022 )) -ne 0 ]]; then
      die "$SHARED_ROOT is not safe to install into (owner $owner, mode $mode; expected owner $(id -un), not group/world-writable). Inspect it, remove or fix it yourself, then re-run."
    fi
  fi
  [[ ! -e "$SHARED_ROOT/.env" ]] \
    || die "$SHARED_ROOT/.env exists: a token there is readable by every account. Delete it; HF_TOKEN belongs in ~/.config/meeting-notes/.env (per account)."
  others="$( { mn_other_users "$APP/"; mn_other_users "$SHARED_ROOT/"; } | sort -u | tr '\n' ' ')"
  [[ -z "${others// /}" ]] \
    || die "MeetingNotes (or its pipeline) is in use by another account: ${others% }. Ask them to quit MeetingNotes (menu bar > Quit), then re-run. It is never quit from here."
}

shared_plan() {
  echo "  shared   $SHARED_ROOT (owner $(id -un), world-readable, not world-writable): pipeline, venv, uv, models"
  echo "  copy     pipeline source to $SHARED_PIPELINE (no .env, no tests, no recordings)"
  echo "  sync     Python environment in $SHARED_PIPELINE/.venv with a uv-managed Python 3.12 in $SHARED_ROOT/python"
  echo "  build    FluidAudio diarization + live caption helpers (swift build -c release --product ...)"
  if [[ "$SKIP_MODELS" -eq 0 ]]; then
    echo "  models   whisper + embeddings into $SHARED_HUB, FluidAudio into $SHARED_ROOT/models/fluidaudio;"
    echo "           live caption model (WhisperKit, ~217 MB, no login) into $SHARED_ROOT/models/whisperkit;"
    echo "           Ollama summary model in the running Ollama (shared by the accounts, see docs)"
  fi
  echo "  app      scripts/build-app.sh: build, sign and install $APP (pipeline: $SHARED_PIPELINE)"
  [[ -n "$ADMIN_NOTE" ]] && echo "  note     $ADMIN_NOTE"
  [[ -d "$LEGACY_APP" ]] && echo "  note     the per-user $LEGACY_APP stays until you remove it (asked at the end)"
  [[ -f "$ROOT/.env" ]] && echo "  token    HF_TOKEN from .env copied to $USER_ENV (mode 600, this account only, value never shown)"
  echo "  later    other accounts run $SHARED_ROOT/bin/meeting-notes-user-setup once, then open the app"
}

write_marker() {
  local file="$SHARED_ROOT/shared-install.json"
  printf '+ write %s\n' "$file"
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  cat > "$file.tmp" <<JSON
{
  "version": 1,
  "root": "$SHARED_ROOT",
  "pipeline_dir": "$SHARED_PIPELINE",
  "uv_path": "$SHARED_UV",
  "models_dir": "$SHARED_ROOT/models",
  "hf_hub_cache": "$SHARED_HUB",
  "app": "$APP",
  "owner": "$(id -un)",
  "installed": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
  mv "$file.tmp" "$file"
}

# HF_TOKEN stays per account: copy only that line from the repo .env to ~/.config/meeting-notes/.env (mode 600).
copy_token() {
  [[ -f "$ROOT/.env" ]] && grep -q '^HF_TOKEN=' "$ROOT/.env" || return 0
  if [[ -f "$USER_ENV" ]] && grep -q '^HF_TOKEN=' "$USER_ENV"; then return 0; fi
  printf '+ copy HF_TOKEN from %s to %s (mode 600, value not shown)\n' "$ROOT/.env" "$USER_ENV"
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  mkdir -p "$(dirname "$USER_ENV")"
  chmod 700 "$(dirname "$USER_ENV")"
  ( umask 077; grep '^HF_TOKEN=' "$ROOT/.env" | head -n 1 >> "$USER_ENV" )
  chmod 600 "$USER_ENV"
}

shared_install() {
  local build_args=(--install-dir "$APP_DIR" --pipeline-dir "$SHARED_PIPELINE" --uv-path "$SHARED_UV")
  [[ "$FORCE" -eq 1 ]] && build_args+=(--force)
  umask 022

  say "Shared directory $SHARED_ROOT"
  run mkdir -p "$SHARED_ROOT/bin" "$SHARED_HUB" "$SHARED_ROOT/models/fluidaudio"
  run chmod 755 "$SHARED_ROOT"
  run rsync -a --delete --exclude .venv --exclude __pycache__ --exclude .pytest_cache --exclude .ruff_cache \
    --exclude tests --exclude bench --exclude .env "$ROOT/pipeline/" "$SHARED_PIPELINE/"
  run install -m 755 "$UV" "$SHARED_UV"
  run install -m 755 "$ROOT/scripts/shared/meeting-notes" "$SHARED_CLI"
  run install -m 755 "$ROOT/scripts/user-setup.sh" "$SHARED_ROOT/bin/meeting-notes-user-setup"
  write_marker

  say "Python pipeline environment (shared)"
  run env UV_PYTHON_INSTALL_DIR="$SHARED_ROOT/python" UV_PYTHON_PREFERENCE=only-managed \
    "$SHARED_UV" sync --project "$SHARED_PIPELINE" --frozen --no-dev --compile-bytecode
  run "$SHARED_PIPELINE/.venv/bin/python" -m compileall -q "$SHARED_PIPELINE/src"  # other accounts cannot write .pyc

  say "FluidAudio diarization and live caption helpers"
  run swift build -c release --package-path "$ROOT/app" --product MeetingNotesDiarize
  run swift build -c release --package-path "$ROOT/app" --product MeetingNotesCaptions

  if [[ "$SKIP_MODELS" -eq 0 ]]; then
    say "Models into the shared store (default config; already downloaded ones are skipped)"
    run env MEETING_NOTES_CONFIG=/dev/null MEETING_NOTES_DIARIZE_CLI="$ROOT/app/.build/release/MeetingNotesDiarize" \
      "$SHARED_CLI" setup
    # Live captions ("Fast captions"): other accounts cannot write the shared store, so the model is fetched here
    # (ungated, pinned commit, no token); each account's Neural Engine cache is built on its first use.
    run env -u HF_TOKEN "$ROOT/app/.build/release/MeetingNotesCaptions" --prepare --models "$SHARED_ROOT/models/whisperkit"
  fi

  say "Permissions: readable by every account, writable only by $(id -un)"
  run chmod -R u+rwX,go+rX,go-w "$SHARED_ROOT"

  say "Menu bar app"
  run "$ROOT/scripts/build-app.sh" "${build_args[@]}"

  copy_token

  if [[ -d "$LEGACY_APP" && "$LEGACY_APP" != "$APP" ]]; then
    if [[ -n "$(mn_app_pids "$LEGACY_APP")" ]]; then  # never quit or move a running (maybe recording) app
      echo "  keep     $LEGACY_APP is running: quit it when idle, then: mv \"$LEGACY_APP\" ~/.Trash/"
    elif [[ "$DRY_RUN" -eq 0 ]] && ask "Move the old per-user $LEGACY_APP to the Trash (two copies confuse macOS)?"; then
      run mv "$LEGACY_APP" "$HOME/.Trash/MeetingNotes-$(date +%Y%m%d%H%M%S).app"
    else
      echo "  keep     $LEGACY_APP (remove it yourself to avoid two copies: mv \"$LEGACY_APP\" ~/.Trash/)"
    fi
  fi

  say "Check"
  run "$SHARED_CLI" doctor || true
}

shared_done() {
  cat <<EOF

Done$([[ "$DRY_RUN" -eq 1 ]] && echo " (dry run: nothing was changed)"). Shared install in $SHARED_ROOT, app $APP.
This account ($(id -un)):
  1. Open the app:  open "$APP"   (Microphone and Screen & System Audio grants usually carry over: same signature)
  2. If asked: allow Microphone; System Settings > Privacy & Security > Screen & System Audio Recording.
  3. Settings > Launch at Login again if you used it (the app moved).
Every other account (log in to it, then in Terminal, no admin needed):
  $SHARED_ROOT/bin/meeting-notes-user-setup --open
  then allow Microphone and Screen & System Audio Recording for MeetingNotes in that account.
Summaries use the Ollama on 127.0.0.1:11434 (this account's; it keeps running under fast user switching).
EOF
  if [[ -n "$ADMIN_NOTE" ]]; then
    cat <<EOF
Optional, needs an admin (this script never runs sudo): move the app to /Applications (each account may need to
grant Microphone and Screen & System Audio again):
  sudo ditto "$APP" /Applications/MeetingNotes.app && sudo rm -rf "$APP"
EOF
  fi
}
