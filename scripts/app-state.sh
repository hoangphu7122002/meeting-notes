# shellcheck shell=bash
# Sourced by scripts/build-app.sh and scripts/install.sh: is the installed MeetingNotes running, and busy?
# Never quits or signals anything itself.
#
# Env (tests): MN_APP_STATE_FILE  the app's state.json (default ~/Library/Application Support/MeetingNotes/state.json)

MN_APP_STATE_FILE="${MN_APP_STATE_FILE:-$HOME/Library/Application Support/MeetingNotes/state.json}"

# PIDs of this account's app main executable inside bundle $1 (not the MeetingNotesDiarize helper next to it).
mn_app_pids() {
  pgrep -U "$(id -u)" -f "^$1/Contents/MacOS/MeetingNotes( |\$)" 2>/dev/null || true
}

# Other accounts (user names, one per line) running an executable under path $1, e.g. a shared
# app bundle or pipeline dir. Their apps are never quit from here (fast user switching: ask them to quit).
mn_other_users() {
  ps -axo uid=,user=,command= 2>/dev/null \
    | awk -v me="$(id -u)" -v pat="$1" '$1 != me && index($3, pat) == 1 {print $2}' | sort -u
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
