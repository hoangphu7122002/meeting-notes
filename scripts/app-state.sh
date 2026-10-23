# shellcheck shell=bash
# Sourced by scripts/build-app.sh and scripts/install.sh: is the installed MeetingNotes running, and busy?
# Never quits or signals anything itself.
#
# Env (tests): MN_APP_STATE_FILE  the app's state.json (default ~/Library/Application Support/MeetingNotes/state.json)

MN_APP_STATE_FILE="${MN_APP_STATE_FILE:-$HOME/Library/Application Support/MeetingNotes/state.json}"

# PIDs of the app's main executable inside bundle $1 (not the MeetingNotesDiarize helper next to it).
mn_app_pids() {
  pgrep -f "$1/Contents/MacOS/MeetingNotes( |\$)" 2>/dev/null || true
}

# recording | processing | idle | unknown, from the app's state.json. Only meaningful while the app runs.
mn_app_activity() {
  local state
  if [[ ! -r "$MN_APP_STATE_FILE" ]]; then
    echo unknown
    return
  fi
  state="$(plutil -extract state raw -o - "$MN_APP_STATE_FILE" 2>/dev/null || echo unknown)"
  case "$state" in
    starting|recording|paused|stopping) echo recording ;;
    idle)
      if plutil -extract processing.folder raw -o - "$MN_APP_STATE_FILE" >/dev/null 2>&1; then
        echo processing
      else
        echo idle
      fi
      ;;
    *) echo unknown ;;
  esac
}
