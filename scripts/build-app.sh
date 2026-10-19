#!/usr/bin/env bash
# Build MeetingNotes.app (release), ad-hoc sign it and install it to ~/Applications.
#
# Usage: scripts/build-app.sh [--no-install]
# Env:   CODESIGN_IDENTITY  signing identity (default "-" = ad-hoc). A stable self-signed identity
#                           keeps macOS privacy permissions across rebuilds.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PKG="$ROOT/app"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/MeetingNotes.app"
INSTALL_DIR="$HOME/Applications"
BUNDLE_ID="com.hoangphu.meetingnotes"
VERSION="0.1.0"
IDENTITY="${CODESIGN_IDENTITY:--}"
INSTALL=1

for arg in "$@"; do
  case "$arg" in
    --no-install) INSTALL=0 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 64 ;;
  esac
done

xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }

PIPELINE_DIR="$ROOT/pipeline"
UV_PATH="$(command -v uv || true)"
if [[ -z "$UV_PATH" && -x "$HOME/.local/bin/uv" ]]; then UV_PATH="$HOME/.local/bin/uv"; fi
UV_PATH="${UV_PATH:-/opt/homebrew/bin/uv}"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

echo "==> swift build -c release"
swift build -c release --package-path "$APP_PKG"
BIN_DIR="$(swift build -c release --package-path "$APP_PKG" --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MeetingNotes" "$APP/Contents/MacOS/MeetingNotes"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>MeetingNotes</string>
  <key>CFBundleDisplayName</key><string>Meeting Notes</string>
  <key>CFBundleExecutable</key><string>MeetingNotes</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Meeting Notes records your microphone during meetings you choose to record.</string>
  <key>NSScreenCaptureUsageDescription</key><string>Meeting Notes records system audio (other participants) during meetings you choose to record. No screen content is saved.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Meeting Notes records system audio (other participants) during meetings you choose to record.</string>
  <key>MNPipelineDir</key><string>$(xml_escape "$PIPELINE_DIR")</string>
  <key>MNUvPath</key><string>$(xml_escape "$UV_PATH")</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist"

echo "==> codesign ($IDENTITY)"
codesign --force --deep --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP"

if [[ "$INSTALL" -eq 1 ]]; then
  DEST="$INSTALL_DIR/MeetingNotes.app"
  if pgrep -f "$DEST/Contents/MacOS/MeetingNotes" >/dev/null 2>&1; then
    echo "==> quitting running MeetingNotes"
    osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      pgrep -f "$DEST/Contents/MacOS/MeetingNotes" >/dev/null 2>&1 || break
      sleep 0.5
    done
    pkill -f "$DEST/Contents/MacOS/MeetingNotes" >/dev/null 2>&1 || true
  fi
  echo "==> installing to $DEST"
  mkdir -p "$INSTALL_DIR"
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  echo "Installed. Launch with: open \"$DEST\""
else
  echo "Built $APP (not installed)"
fi
