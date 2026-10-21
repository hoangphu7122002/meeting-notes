#!/usr/bin/env bash
# Swift architecture rules (grep only). Exit 1 on violations.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=app/Sources
fail=0
MAX_LINES=300
# WP-B flips this to 1 once long files are split.
LONG_FILES_FATAL=${LONG_FILES_FATAL:-0}

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

# File length.
long=$(find "$SRC" -name '*.swift' ! -name 'L10n.swift' -exec wc -l {} + | awk -v m=$MAX_LINES '$2!="total" && $1>m {print $1, $2}' || true)
if [ -n "$long" ]; then
  if [ "$LONG_FILES_FATAL" = 1 ]; then echo "ERROR: Swift files over $MAX_LINES lines:"; fail=1
  else echo "WARNING: Swift files over $MAX_LINES lines (non-fatal until WP-B; LONG_FILES_FATAL=1 to enforce):"; fi
  echo "$long"
fi

[ "$fail" = 0 ] && echo "swift arch: ok"
exit "$fail"
