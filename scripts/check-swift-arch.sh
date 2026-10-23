#!/usr/bin/env bash
# Swift architecture rules (grep only). Exit 1 on violations.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=app/Sources
fail=0
MAX_LINES=300
# LONG_FILES_FATAL=0 downgrades the length check to a warning.
LONG_FILES_FATAL=${LONG_FILES_FATAL:-1}

# check <target> <forbidden-import-regex>
check_forbidden() {
  local target=$1 pattern=$2 hits
  hits=$(grep -rnE "^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+($pattern)\b" "$SRC/$target" --include='*.swift' || true)
  if [ -n "$hits" ]; then
    echo "ERROR: $target must not import ($pattern):"; echo "$hits"; fail=1
  fi
}

check_forbidden MeetingNotesCore 'SwiftUI|AppKit|ScreenCaptureKit|CoreAudio|UserNotifications|ServiceManagement|IOKit'
check_forbidden MeetingNotesUI 'ScreenCaptureKit|CoreAudio|UserNotifications|IOKit|AVFoundation'

# Previews: allowlist only.
hits=$(grep -rnE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+' "$SRC/MeetingNotesPreviews" --include='*.swift' \
  | grep -vE 'import[[:space:]]+(Foundation|AppKit|SwiftUI|MeetingNotesCore|MeetingNotesUI)[[:space:]]*$' || true)
if [ -n "$hits" ]; then
  echo "ERROR: MeetingNotesPreviews may import only Foundation/AppKit/SwiftUI/MeetingNotesCore/MeetingNotesUI:"
  echo "$hits"; fail=1
fi

# Diarize helper: allowlist only; nothing else may import FluidAudio.
hits=$(grep -rnE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+' "$SRC/MeetingNotesDiarize" --include='*.swift' \
  | grep -vE 'import[[:space:]]+(Foundation|AVFoundation|CoreML|FluidAudio)[[:space:]]*$' || true)
if [ -n "$hits" ]; then
  echo "ERROR: MeetingNotesDiarize may import only Foundation/AVFoundation/CoreML/FluidAudio:"; echo "$hits"; fail=1
fi
hits=$(grep -rnE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+FluidAudio\b' "$SRC" --include='*.swift' \
  | grep -v "^$SRC/MeetingNotesDiarize/" || true)
if [ -n "$hits" ]; then
  echo "ERROR: only MeetingNotesDiarize may import FluidAudio:"; echo "$hits"; fail=1
fi

# Caption kit: Foundation only (shared by the app and the caption helper).
hits=$(grep -rnE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+' "$SRC/MeetingNotesCaptionKit" --include='*.swift' \
  | grep -vE 'import[[:space:]]+Foundation[[:space:]]*$' || true)
if [ -n "$hits" ]; then
  echo "ERROR: MeetingNotesCaptionKit may import only Foundation:"; echo "$hits"; fail=1
fi

# Caption helper: allowlist only; nothing else may import WhisperKit (it stays out of the app process).
hits=$(grep -rnE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+' "$SRC/MeetingNotesCaptions" --include='*.swift' \
  | grep -vE 'import[[:space:]]+(Foundation|CoreML|MeetingNotesCaptionKit|WhisperKit)[[:space:]]*$' || true)
if [ -n "$hits" ]; then
  echo "ERROR: MeetingNotesCaptions may import only Foundation/CoreML/MeetingNotesCaptionKit/WhisperKit:"; echo "$hits"; fail=1
fi
hits=$(grep -rnE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+WhisperKit\b' "$SRC" --include='*.swift' \
  | grep -v "^$SRC/MeetingNotesCaptions/" || true)
if [ -n "$hits" ]; then
  echo "ERROR: only MeetingNotesCaptions may import WhisperKit:"; echo "$hits"; fail=1
fi

# Launch rules: Foundation only (the launcher agent links nothing heavier).
hits=$(grep -rnE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+' "$SRC/MeetingNotesLaunch" --include='*.swift' \
  | grep -vE 'import[[:space:]]+Foundation[[:space:]]*$' || true)
if [ -n "$hits" ]; then
  echo "ERROR: MeetingNotesLaunch may import only Foundation:"; echo "$hits"; fail=1
fi

# Launcher agent (always running): allowlist only, no Core/UI (their frameworks would load into it).
hits=$(grep -rnE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+' "$SRC/MeetingNotesLauncher" --include='*.swift' \
  | grep -vE 'import[[:space:]]+(Foundation|AppKit|CoreAudio|os|MeetingNotesLaunch)[[:space:]]*$' || true)
if [ -n "$hits" ]; then
  echo "ERROR: MeetingNotesLauncher may import only Foundation/AppKit/CoreAudio/os/MeetingNotesLaunch:"; echo "$hits"; fail=1
fi

# File length.
long=$(find "$SRC" -name '*.swift' ! -name 'L10n.swift' -exec wc -l {} + | awk -v m=$MAX_LINES '$2!="total" && $1>m {print $1, $2}' || true)
if [ -n "$long" ]; then
  if [ "$LONG_FILES_FATAL" = 1 ]; then echo "ERROR: Swift files over $MAX_LINES lines:"; fail=1
  else echo "WARNING: Swift files over $MAX_LINES lines (non-fatal: LONG_FILES_FATAL=0):"; fi
  echo "$long"
fi

[ "$fail" = 0 ] && echo "swift arch: ok"
exit "$fail"
