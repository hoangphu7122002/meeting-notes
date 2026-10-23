#!/usr/bin/env bash
# Build MeetingNotes.app (release) with the MeetingNotesDiarize helper and the MeetingNotesLauncher agent
# ("open the app when a meeting starts", Contents/Library/LaunchAgents), sign them with the local identity and
# install the app to ~/Applications.
#
# Usage: scripts/build-app.sh [--no-install] [--force] [--install-dir DIR] [--pipeline-dir DIR] [--uv-path PATH]
#                             [--packaged] [--version X] [--out DIR]
#        --force         quit a running MeetingNotes even while it records (default: refuse; idle apps are quit)
#        --packaged      release build (scripts/release.sh): bundle the pipeline source (Resources/pipeline) and uv
#                        (MacOS/uv), Info.plist MNPackaged instead of MNPipelineDir/MNUvPath; implies --no-install
#        --version       CFBundleShortVersionString (default 0.1.0)
#        --out           where the bundle is assembled (default build/)
#        --install-dir   where the app goes (default ~/Applications; install.sh --shared: /Applications)
#        --pipeline-dir  baked as Info.plist MNPipelineDir (default: this repo's pipeline/)
#        --uv-path       baked as Info.plist MNUvPath (default: uv on PATH)
# Env:   CODESIGN_IDENTITY  signing identity. Default: the local self-signed identity created by
#                           scripts/setup-signing.sh (created on first build), so macOS keeps
#                           Microphone / Screen & System Audio permissions across rebuilds.
#                           "-" = ad-hoc (permissions reset on every rebuild). A stable self-signed identity
#                           keeps macOS privacy permissions across rebuilds.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PKG="$ROOT/app"
BUILD_DIR="$ROOT/build"
INSTALL_DIR="$HOME/Applications"
BUNDLE_ID="com.hoangphu.meetingnotes"
VERSION="0.1.0"
IDENTITY="${CODESIGN_IDENTITY:-}"
INSTALL=1
FORCE=0
HELPER="MeetingNotesDiarize"  # FluidAudio diarization CLI; the app passes its path to the pipeline worker
LAUNCHER="MeetingNotesLauncher"  # per-user agent (SMAppService.agent), registered by the app's Settings
LAUNCHER_LABEL="$BUNDLE_ID.launcher"

PIPELINE_DIR="$ROOT/pipeline"
UV_PATH=""
PACKAGED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-install) INSTALL=0 ;;
    --force) FORCE=1 ;;
    --packaged) PACKAGED=1; INSTALL=0 ;;
    --install-dir|--pipeline-dir|--uv-path|--version|--out)
      [[ $# -ge 2 && -n "$2" ]] || { echo "missing value for $1" >&2; exit 64; }
      case "$1" in
        --install-dir) INSTALL_DIR="$2" ;;
        --pipeline-dir) PIPELINE_DIR="$2" ;;
        --uv-path) UV_PATH="$2" ;;
        --version) VERSION="$2" ;;
        --out) BUILD_DIR="$2" ;;
      esac
      shift ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
  shift
done

# shellcheck source=scripts/app-state.sh
source "$ROOT/scripts/app-state.sh"

xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }

if [[ -z "$UV_PATH" ]]; then
  UV_PATH="$(command -v uv || true)"
  if [[ -z "$UV_PATH" && -x "$HOME/.local/bin/uv" ]]; then UV_PATH="$HOME/.local/bin/uv"; fi
  UV_PATH="${UV_PATH:-/opt/homebrew/bin/uv}"
fi
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "invalid --version $VERSION (expected X.Y.Z)" >&2; exit 64; }
APP="$BUILD_DIR/MeetingNotes.app"
if [[ "$PACKAGED" -eq 1 && ! -x "$UV_PATH" ]]; then echo "uv not found at $UV_PATH (needed in the packaged app)" >&2; exit 1; fi

DEST="$INSTALL_DIR/MeetingNotes.app"
others="$(mn_other_users "$DEST/" | tr '\n' ' ')"
if [[ "$INSTALL" -eq 1 && -n "$others" ]]; then  # a shared app open in another account: never replaced under it
  echo "MeetingNotes ($DEST) is open in another account: $others. Ask them to quit it (menu bar > Quit), then re-run." >&2
  exit 1
fi
if [[ "$INSTALL" -eq 1 && "$FORCE" -eq 0 && -n "$(mn_app_pids "$DEST")" ]]; then
  case "$(mn_app_activity)" in
    recording|unknown)
      echo "MeetingNotes is recording (or its state is unknown); not quitting it. Stop the recording, or pass --force." >&2
      exit 1 ;;
  esac
fi

echo "==> swift build -c release"
swift build -c release --package-path "$APP_PKG"
BIN_DIR="$(swift build -c release --package-path "$APP_PKG" --show-bin-path)"
for product in "$HELPER" "$LAUNCHER"; do
  [[ -x "$BIN_DIR/$product" ]] || { echo "missing $BIN_DIR/$product after the build" >&2; exit 1; }
done

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MeetingNotes" "$APP/Contents/MacOS/MeetingNotes"
cp "$BIN_DIR/$HELPER" "$APP/Contents/MacOS/$HELPER"
cp "$BIN_DIR/$LAUNCHER" "$APP/Contents/MacOS/$LAUNCHER"
cp "$APP_PKG/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"  # regenerate: scripts/make-icon.sh
# launchd plist for SMAppService.agent(plistName:): each account registers its own copy (gui/<uid> domain).
mkdir -p "$APP/Contents/Library/LaunchAgents"
cat > "$APP/Contents/Library/LaunchAgents/$LAUNCHER_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LAUNCHER_LABEL</string>
  <key>BundleProgram</key><string>Contents/MacOS/$LAUNCHER</string>
  <key>AssociatedBundleIdentifiers</key><array><string>$BUNDLE_ID</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Library/LaunchAgents/$LAUNCHER_LABEL.plist"

if [[ "$PACKAGED" -eq 1 ]]; then
  # Pipeline source + lockfile only (no .venv, tests, bench, .env, caches); the first-run setup copies it to
  # ~/Library/Application Support/MeetingNotes/runtime and syncs it there (never inside the signed bundle).
  mkdir -p "$APP/Contents/Resources/pipeline"
  for entry in pyproject.toml uv.lock .python-version config.example.toml; do
    if [[ -f "$PIPELINE_DIR/$entry" ]]; then cp "$PIPELINE_DIR/$entry" "$APP/Contents/Resources/pipeline/"; fi
  done
  rsync -a --exclude __pycache__ --exclude '*.pyc' --exclude .DS_Store "$PIPELINE_DIR/src/" "$APP/Contents/Resources/pipeline/src/"
  cp "$UV_PATH" "$APP/Contents/MacOS/uv"
  chmod 755 "$APP/Contents/MacOS/uv"
  cp "$ROOT/scripts/release/THIRD-PARTY-NOTICES.txt" "$APP/Contents/Resources/"
  LOCATION_KEYS="  <key>MNPackaged</key><true/>"
else
  LOCATION_KEYS="  <key>MNPipelineDir</key><string>$(xml_escape "$PIPELINE_DIR")</string>
  <key>MNUvPath</key><string>$(xml_escape "$UV_PATH")</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>MeetingNotes</string>
  <key>CFBundleDisplayName</key><string>Meeting Notes</string>
  <key>CFBundleExecutable</key><string>MeetingNotes</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><false/>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
      <key>CFBundleURLSchemes</key><array><string>meetingnotes</string></array>
    </dict>
  </array>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Meeting Notes records your microphone during meetings you choose to record.</string>
  <key>NSScreenCaptureUsageDescription</key><string>Meeting Notes records system audio (other participants) during meetings you choose to record. No screen content is saved.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Meeting Notes records system audio (other participants) during meetings you choose to record.</string>
$LOCATION_KEYS
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist"

if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$("$ROOT/scripts/setup-signing.sh")"
fi
echo "==> codesign ($IDENTITY)"
# Inside out: the helpers first (own identifiers), then the app, whose seal covers the signed helpers.
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID.diarize" "$APP/Contents/MacOS/$HELPER"
codesign --force --sign "$IDENTITY" --identifier "$LAUNCHER_LABEL" "$APP/Contents/MacOS/$LAUNCHER"
if [[ "$PACKAGED" -eq 1 ]]; then
  codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID.uv" "$APP/Contents/MacOS/uv"
fi
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict --deep "$APP"

if [[ "$INSTALL" -eq 1 ]]; then
  if [[ -n "$(mn_other_users "$DEST/")" ]]; then  # opened in another account during the build
    echo "MeetingNotes was opened in another account during the build; not installing. Built: $APP" >&2
    exit 1
  fi
  if [[ -n "$(mn_app_pids "$DEST")" ]]; then
    if [[ "$FORCE" -eq 0 && "$(mn_app_activity)" =~ ^(recording|unknown)$ ]]; then  # started during the build
      echo "MeetingNotes started recording during the build; not installing. Built: $APP" >&2
      exit 1
    fi
    echo "==> quitting running MeetingNotes"
    osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      [[ -n "$(mn_app_pids "$DEST")" ]] || break
      sleep 0.5
    done
    for pid in $(mn_app_pids "$DEST"); do kill "$pid" 2>/dev/null || true; done  # by PID only
  fi
  echo "==> installing to $DEST"
  mkdir -p "$INSTALL_DIR"
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  chmod -R go+rX,go-w "$DEST"  # readable by every account when installed to /Applications (shared install)
  echo "Installed. Launch with: open \"$DEST\""
else
  echo "Built $APP (not installed)"
fi
