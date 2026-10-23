# Release checklist (dmg for newcomers)

What a release is: `MeetingNotes-<version>.dmg` on GitHub Releases. A newcomer downloads it, drags the app to
Applications, approves it once in System Settings (Open Anyway: no Apple Developer account, so the app is
self-signed and not notarized), opens it and presses **Cài đặt / Set up**. The app's first-run setup downloads the
rest (~3.4 GB): Python 3.12 + locked wheels (uv), whisper, FluidAudio, then checks Ollama (guides to ollama.com,
never installs it) and pulls the summary model. No terminal, no Hugging Face token.

## What is in the dmg

| Item | Source |
|---|---|
| `MeetingNotes.app` (Info.plist `MNPackaged`, version = release) | `scripts/build-app.sh --packaged` |
| `Contents/MacOS/{MeetingNotes, MeetingNotesDiarize, uv}` | `swift build -c release`, the release Mac's uv |
| `Contents/Resources/pipeline/` (source, `pyproject.toml`, `uv.lock`) | `pipeline/` without `.venv`, tests, bench, `.env` |
| `Contents/Resources/THIRD-PARTY-NOTICES.txt` | `scripts/release/THIRD-PARTY-NOTICES.txt` |
| `Applications` link, `ĐỌC TRƯỚC - Read me first.txt` (Open Anyway steps, vi + en) | `scripts/release/dmg-readme.txt` |

Never in it: `.env`, `HF_TOKEN`, models, recordings, `shared-install.json` (`release.sh` checks and aborts).
Size: ~31 MB (0.1.0).

## Packaged runtime (on the user's Mac)

`~/Library/Application Support/MeetingNotes/runtime/` (`RuntimeLayout`, Core): `pipeline/` (copied from the bundle,
`.venv` inside), `python/`, `bin/uv`, `cache/uv`, `models/{huggingface/hub,fluidaudio}`, `shared-install.json`
(`"mode": "packaged"`) and `setup-state.json`. Setup steps (`SetupMachine`): runtime → speech → diarization →
ollama → summary; each resumable, cancellable, at `nice 10`; paused while recording or a notes job runs. After an
update only the runtime step re-runs (by itself). Uninstall: delete the app and that folder (Ollama models stay
in Ollama). Logs: `~/Library/Logs/MeetingNotes/setup.log`.

## Checklist

1. `git status` clean on `master`; `make ci` green (lint, lint-arch, pytest, swift test).
2. Pick the version (`X.Y.Z`); bump `pipeline/pyproject.toml` `version` (the default) or pass `--version`.
3. `scripts/release.sh --dry-run --version X.Y.Z`, then `scripts/release.sh --version X.Y.Z` (or `make release
   ARGS="--version X.Y.Z"`). It never installs, quits the running app or touches `/Applications`.
   Sign on the release Mac only: the stable self-signed identity (`scripts/setup-signing.sh`) keeps users'
   Microphone / Screen & System Audio grants across updates; losing its key means everyone re-grants once.
4. Smoke test the dmg on this Mac without installing: `hdiutil attach build/release/MeetingNotes-X.Y.Z.dmg`,
   check the window (app, Applications link, read-me), `codesign -dvv` the app, `hdiutil detach`.
5. Fresh-Mac acceptance (plan Phase 7 M7), in a new macOS user account or a colleague's Mac: browser download →
   drag to Applications → Open Anyway → Set up → Ollama guide → 2 permissions → a 2 min test meeting produces notes;
   then install the next version over it and confirm permissions survive and only the runtime step re-runs.
6. Publish (manual, only after 5): `git tag vX.Y.Z && git push origin vX.Y.Z`, then
   `gh release create vX.Y.Z build/release/MeetingNotes-X.Y.Z.dmg build/release/SHA256SUMS.txt --title "Meeting Notes X.Y.Z" --notes-file <notes>`.
   Release notes: changes, dmg size, first-run download size, the Open Anyway steps, `SHA256SUMS.txt`.
7. Never commit `build/` or a `.dmg`.

The workflow `.github/workflows/release-dmg.yml` is disabled (manual `workflow_dispatch` only, uploads an artifact,
no release). It signs ad-hoc, so its builds are for testing only.

## Open before the first public release

- M7 fresh-Mac run (above), including Gatekeeper on the bundled helpers (`MeetingNotesDiarize`, `uv` copied out of
  the bundle has its quarantine flag removed by the app).
- Release visibility (repo is public today) and whether to ship an in-app updater (M6).
- CC-BY notices also in Settings › About (today: `THIRD-PARTY-NOTICES.txt` in the bundle).
- Bundle id `com.hoangphu.meetingnotes` vs a company id (switching later resets permissions).
