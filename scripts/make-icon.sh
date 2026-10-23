#!/usr/bin/env bash
# Regenerate app/Resources/AppIcon.icns from app/Resources/AppIcon.svg (macOS only: WebKit via a small Swift
# renderer + iconutil; no third-party tools). Usage: scripts/make-icon.sh [--png SIZE OUT.png]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SVG="$ROOT/app/Resources/AppIcon.svg"
SWIFT="$ROOT/scripts/render-svg.swift"
if [[ "${1:-}" == "--png" ]]; then swift "$SWIFT" "$SVG" "$3" "$2"; exit 0; fi
SET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  swift "$SWIFT" "$SVG" "$SET/icon_${s}x${s}.png" "$s"
  swift "$SWIFT" "$SVG" "$SET/icon_${s}x${s}@2x.png" "$((s * 2))"
done
iconutil -c icns "$SET" -o "$ROOT/app/Resources/AppIcon.icns"
echo "wrote app/Resources/AppIcon.icns"
