#!/usr/bin/env bash
# Build the release dmg for newcomers: MeetingNotes-<version>.dmg + SHA256SUMS.txt in build/release/.
# Never installs, quits or touches /Applications, ~/Applications or a running MeetingNotes, and never uploads:
# publishing is CI's job: push a vX.Y.Z tag (make release-tag) and .github/workflows/release.yml publishes it.
#
# Usage: scripts/release.sh [--version X.Y.Z] [--dry-run] [--out DIR]
#   --version  release version (default: scripts/version.sh, i.e. the vX.Y.Z tag on HEAD or the latest one)
#   --dry-run  check the Mac and print every command; build nothing
#   --out      output directory (default build/release)
# Env:   CODESIGN_IDENTITY  as for build-app.sh (default: the stable local self-signed identity, so Microphone and
#                           Screen & System Audio grants survive updates; "-" = ad-hoc, e.g. in CI)
#        UV                 uv binary to bundle (default: uv on PATH)
#
# The app bundles: MeetingNotes, MeetingNotesDiarize (FluidAudio), MeetingNotesLauncher (agent), uv, the
# pipeline source + uv.lock (Contents/Resources/pipeline) and third-party notices. Python, wheels and model weights
# are downloaded by the app's first-run setup, never shipped. No .env, token, model or recording is ever copied
# (checked below).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build/release"
VERSION=""
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --version|--out)
      [[ $# -ge 2 && -n "$2" ]] || { echo "missing value for $1" >&2; exit 64; }
      if [[ "$1" == --version ]]; then VERSION="${2#v}"; else OUT="$2"; fi
      shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (see --help)" >&2; exit 64 ;;
  esac
  shift
done

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
run() {
  printf '+ %s\n' "$*"
  [[ "$DRY_RUN" -eq 1 ]] || "$@"
}

if [[ -z "$VERSION" ]]; then
  VERSION="$("$ROOT/scripts/version.sh")"
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid version '$VERSION' (expected X.Y.Z)"
case "$OUT" in /*) ;; *) OUT="$ROOT/$OUT" ;; esac
case "$OUT" in
  /Applications*|"$HOME/Applications"*|"$HOME/MeetingNotes"*) die "refusing to write into $OUT" ;;
esac

STAGE="$OUT/stage"
APP="$STAGE/MeetingNotes.app"
DMG_ROOT="$OUT/dmg-root"
DMG="$OUT/MeetingNotes-$VERSION.dmg"
README_NAME="ĐỌC TRƯỚC - Read me first.txt"
UV="${UV:-$(command -v uv || true)}"
[[ -z "$UV" && -x "$HOME/.local/bin/uv" ]] && UV="$HOME/.local/bin/uv"

say "Checking this Mac"
[[ "$(uname -s)" == Darwin ]] || die "macOS only"
[[ "$(uname -m)" == arm64 ]] || die "build on Apple Silicon (the app and its models are arm64 only)"
for tool in swift hdiutil codesign shasum rsync ditto plutil; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found (Xcode Command Line Tools)"
done
[[ -n "$UV" && -x "$UV" ]] || die "uv not found (brew install uv, or set UV=/path/to/uv)"
file "$UV" | grep -q arm64 || die "$UV is not an arm64 binary"
[[ -f "$ROOT/pipeline/uv.lock" ]] || die "pipeline/uv.lock missing"
if [[ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]]; then
  echo "warning: the working tree has uncommitted changes; the release will contain them" >&2
fi
free_gb="$(df -g "$ROOT" | awk 'NR==2 {print $4}')"
[[ "${free_gb:-0}" -ge 2 ]] || die "less than 2 GB free"

say "Plan (version $VERSION, uv $("$UV" --version | awk '{print $2}'))"
echo "  build    scripts/build-app.sh --packaged (release config, signed, NOT installed) into $STAGE"
echo "  check    signature, Info.plist MNPackaged, no .env/token/model/recording in the bundle"
echo "  dmg      $DMG (app, Applications link, \"$README_NAME\")"
echo "  sums     $OUT/SHA256SUMS.txt"
echo "  never    install, quit a running app, touch /Applications, upload or tag"

say "Build"
run rm -rf "$STAGE" "$DMG_ROOT"
run mkdir -p "$STAGE"
run nice -n 10 "$ROOT/scripts/build-app.sh" --packaged --version "$VERSION" --out "$STAGE" --uv-path "$UV"

say "Check the bundle"
if [[ "$DRY_RUN" -eq 0 ]]; then
  codesign --verify --strict --deep "$APP" || die "signature check failed"
  [[ "$(plutil -extract MNPackaged raw -o - "$APP/Contents/Info.plist")" == true ]] || die "MNPackaged missing"
  ! plutil -extract MNPipelineDir raw -o - "$APP/Contents/Info.plist" >/dev/null 2>&1 || die "MNPipelineDir baked in"
  for need in MacOS/MeetingNotes MacOS/MeetingNotesDiarize MacOS/MeetingNotesLauncher \
              Library/LaunchAgents/com.hoangphu.meetingnotes.launcher.plist MacOS/uv Resources/pipeline/uv.lock \
              Resources/pipeline/pyproject.toml Resources/pipeline/src/meeting_notes/entrypoints/cli.py; do
    [[ -e "$APP/Contents/$need" ]] || die "bundle lacks $need"
  done
  leaks="$(find "$APP" \( -name '.env' -o -name '*.env' -o -name '.venv' -o -name '*.wav' -o -name '*.m4a' \
            -o -name '*.safetensors' -o -name '*.mlmodelc' -o -name 'shared-install.json' \) -print)"
  [[ -z "$leaks" ]] || die "files that must never ship: $leaks"
  if grep -rIlE 'HF_TOKEN=[^ "$]|hf_[A-Za-z0-9]{30,}' "$APP/Contents/Resources" >/dev/null 2>&1; then
    die "something that looks like a Hugging Face token is in the bundle (not shown); aborting"
  fi
  echo "ok: signed ($(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)), packaged, no secrets"
else
  echo "+ codesign --verify --strict --deep $APP; plutil MNPackaged; find/grep for .env, tokens, models, recordings"
fi

say "Disk image"
run mkdir -p "$DMG_ROOT"
run ditto "$APP" "$DMG_ROOT/MeetingNotes.app"
run ln -s /Applications "$DMG_ROOT/Applications"
run cp "$ROOT/scripts/release/dmg-readme.txt" "$DMG_ROOT/$README_NAME"
run rm -f "$DMG"
run hdiutil create -quiet -volname "Meeting Notes $VERSION" -srcfolder "$DMG_ROOT" -fs HFS+ -format UDZO \
  -imagekey zlib-level=9 -ov "$DMG"
run hdiutil verify -quiet "$DMG"
run rm -rf "$DMG_ROOT"

say "Checksums"
if [[ "$DRY_RUN" -eq 0 ]]; then
  (cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > SHA256SUMS.txt && cat SHA256SUMS.txt)
  size="$(du -h "$DMG" | awk '{print $1}')"
  echo
  echo "Built $DMG ($size). Not published (docs/release.md: make release-tag, then push the tag)."
else
  echo "+ (cd $OUT && shasum -a 256 $(basename "$DMG") > SHA256SUMS.txt)"
  echo
  echo "Dry run: nothing was built or changed."
fi
