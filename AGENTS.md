# AGENTS.md — meeting-notes

Local-only macOS meeting recorder: Swift/SwiftUI app (`app/`) + Python pipeline (`pipeline/`) that
transcribes, labels speakers and summarizes on the Mac. User docs: [`README.md`](README.md).

## Hard rules

1. **Local only.** No cloud APIs. Network is for model weights (Hugging Face incl. the ungated FluidAudio weights, Ollama registry), the optional HF gated-model access check, `scripts/install.sh` installing tools (Homebrew packages, uv/PyPI wheels, the official Homebrew installer only when Homebrew is missing), and the packaged app's first-run setup (uv-managed Python + the wheels pinned in the bundled `uv.lock`, models). The app never installs Ollama: it links to ollama.com or prints the Homebrew command.
2. **Summaries use local Ollama only** (`ollama_url`, default `127.0.0.1:11434`). Never Claude/OpenAI or any cloud LLM, for summaries or any pipeline step.
3. **Secrets never printed or committed.** `HF_TOKEN` (optional: only the pyannote fallback uses it) lives only in the gitignored root `.env` or the per-account `~/.config/meeting-notes/.env` (never in a shared install's directory); error text goes through `redact()`; the FluidAudio helper never receives it.
4. **Do not touch other projects.** Never start, stop or reset anything on port 55322 (banhloc Supabase DB) or other repos' stacks; stop processes by PID only.
5. **App-to-pipeline contract is frozen** unless both sides change in one commit with tests (see Contracts).
6. **Config keys and env names are public API:** `config.toml` keys, `MEETING_NOTES_*` (incl. `MEETING_NOTES_DIARIZE_CLI`, set by the app for its worker), `HF_TOKEN`, `MN_PIPELINE_DIR`, Info.plist `MNPipelineDir`/`MNUvPath`/`MNPackaged`, UserDefaults keys under `com.hoangphu.meetingnotes`, the shared-install marker `shared-install.json` (`pipeline_dir`, `uv_path`, `hf_hub_cache`, `app`) and its default root `/Users/Shared/MeetingNotes`, the packaged runtime `~/Library/Application Support/MeetingNotes/runtime` (marker `"mode": "packaged"`, `setup-state.json`), `meeting-notes setup --only/--json` events.
7. **Do not move `pipeline/`, `models/` or `.env`:** the installed app and configs point at them.
8. **Build the app only with `scripts/build-app.sh`** (stable local signing identity keeps mic/screen permissions; it bundles and signs the `MeetingNotesDiarize` helper); bundle id `com.hoangphu.meetingnotes`; ad-hoc signing only when asked. Never quit a recording MeetingNotes: `build-app.sh` and `install.sh` refuse unless `--force`; agents never pass `--force` and never run `make install` / `make install-shared` / `make build-app` end to end without the user (use `scripts/install.sh [--shared] --dry-run`). Never run sudo from scripts (print the command). Releases: `scripts/release.sh` (`build-app.sh --packaged`, never installs) writes the dmg to `build/release/`; tagging, `gh release create` and uploads only on the user's explicit request (`docs/release.md`).
9. **Never record without a user action.** Meeting detection only offers. The worker is spawned on demand, never at launch or while recording unless the user enabled live transcription (Settings › Recording › Live transcript while recording, default off); heavy ML imports stay lazy.
10. **English for code, comments, docs.** UI copy lives in `L10n.swift` (Vietnamese default, English). Never commit `build/`, `app/.build`, `models/`, `.venv`, recordings.

## Layout

```
app/Sources/
  MeetingNotesCore/      pure logic, unit-tested: Recording/ Meetings/ Worker/ Control/ Preferences/ Presentation/ Setup/ (first-run setup machine, runtime layout)
  MeetingNotesUI/        SwiftUI views + view state: State/ MainWindow/ Pill/ Notes/ Settings/ Shared/
  MeetingNotes/          executable: main.swift AppDelegate.swift Controller/ Presentation/ Capture/ Pipeline/ System/ Diagnostics/ Setup/
  MeetingNotesPreviews/  offscreen PNG renderer with fake state
  MeetingNotesDiarize/   helper CLI: FluidAudio Core ML diarization of one WAV -> JSON (default engine; bundled in Contents/MacOS)
app/Tests/               Core + UI tests
pipeline/src/meeting_notes/
  config/                settings kernel (Config, TOML + env loader, hf_token, redact)
  domain/                pure: stdlib + numpy/scipy; intervals, signal, speakers, segments, notes rules/markdown, metrics,
                         live_chunks / live_backlog / partial_merge (live transcription policy), voice_check (mic single-voice test)
  application/           use cases + ports.py (Protocols): process_meeting, summarize_meeting, transcribe_blocks, import_audio,
                         live_transcribe (live job), live_reuse (Stop-time reuse of live partials)
  adapters/outbound/     one vendor or sink per file: ffmpeg, wav, meeting folder, fluidaudio CLI (default diarizer), pyannote (fallback), sherpa-onnx (opt-in), mlx, ollama, hf hub, progress
  adapters/inbound/      commands.py (CLI handlers), worker.py (JSON-lines worker)
  entrypoints/           cli.py (argparse main), wiring.py (dependency factory)
pipeline/tests/          unit/{domain,application,adapters} architecture/ e2e/ · pipeline/bench/ (pipeline harness + long fixtures, diarization-only bench, asr, summary, live benches) · pipeline/scripts/ (model converter)
scripts/                 install.sh (one pass, --dry-run, --shared via install-shared.sh) user-setup.sh (per-account step of a shared install) shared/ build-app.sh (--packaged) release.sh + release/ (dmg) app-state.sh setup-signing.sh check-swift-arch.sh
docs/  models/  build/   research + screenshots; model weights (ignored); app bundle output (ignored)
```

## Architecture rules

`make lint-arch` = `pipeline/tests/architecture` (pytest AST scan) + `scripts/check-swift-arch.sh`.
- Python: domain imports pure stdlib, numpy and scipy only (no config, no I/O). Application imports domain, config, numpy/scipy, light stdlib (`os`, `pathlib`, `time`, `traceback`) and its own ports; never adapters. `adapters/outbound` and `adapters/inbound` never import each other. Heavy libs (`mlx*`, `torch`, `pyannote`, `sherpa_onnx`, `onnxruntime`, `huggingface_hub`, `soundfile`) and I/O stdlib (`subprocess`, `urllib`, `shutil`, `ctypes`) live in `adapters/outbound`; `entrypoints/wiring.py` imports those adapters lazily, so the CLI starts without them (tested). Only `entrypoints/` wires adapters to use cases. Python source files stay <= 300 lines.
- Swift: Core imports no SwiftUI/AppKit/ScreenCaptureKit/CoreAudio/UserNotifications/ServiceManagement/IOKit. UI imports no capture or worker frameworks (ScreenCaptureKit, CoreAudio, UserNotifications, IOKit, AVFoundation). Previews import only Foundation/AppKit/SwiftUI/Core/UI. Diarize imports only Foundation/AVFoundation/CoreML/FluidAudio, and nothing else imports FluidAudio. Source files stay <= 300 lines (except `L10n.swift`).

## Contracts

- **Worker protocol** (`meeting-notes worker`, spawned by `WorkerClient.swift`): stdin JSON lines `{"cmd":"process","job","folder","from","force"}`, `warmup`, `cancel`, `release`, `ping`, `quit`; stdout events (`{"event":"worker",...}`, pipeline events tagged with `job`, `{"event":"job_end","exit":0|1|2|3}`). Python: `adapters/outbound/progress_reporter.py` + `adapters/inbound/worker.py`; Swift: `WorkerEvent.swift`, `LiveEvents.swift`.
- **Live transcription** (opt-in): `ready` carries `"features":["live"]`; stdin `{"cmd":"live","job":"live-<id>","folder"}` runs a long job in the serial loop until `{"cmd":"live_stop","job"}` (also implied by `process`, `quit`, EOF); stdout `{"event":"live_segment","job","track":"mic|system","speaker":"Me|Others","seq","start","end","language","text"}` (one per decoded chunk, re-sent on resume; dedupe by `(track, seq)`) and `{"event":"live_status","job","state":"running|deferred|throttled|stopped","backlog_sec","skipped_sec","rtf","reason"}`, then `job_end`. Jobs with the `live-` prefix are routed to `LiveTranscriber.swift`, others to `JobQueue.swift`; `JobQueue` never starts a process job while recording. The live job tails the WAVs (capture code is unaware of it), keeps whisper loaded for the Stop-time job, and writes only `.work/transcript.partial.jsonl`; `process` reuses a chunk only under the strict rule (natural pause, one speaker, no ambiguous segment), so notes equal the offline path. Design and tests: `docs/research/realtime.md`, `realtime-feasibility.md`.
- **Meeting folder** `~/MeetingNotes/<date> <title>/`: `meeting.json` (app writes), `status.json`, `transcript.json`, `.work/`, `notes.md`, `pipeline.log` (pipeline writes; `.work/transcript.partial.jsonl` = live partials, removed at finalize), `pipeline.app.log` (app writes), `mic.m4a` `system.m4a` `mixed.m4a`.
- **Shared install:** `/Users/Shared/MeetingNotes/{pipeline,python,bin,models}` + `shared-install.json`, owner-writable, world-readable. App: `PipelineLocator` (Core) resolves it and runs the worker with `UV_NO_SYNC=1 UV_FROZEN=1`; pipeline: `config/install.py` sets `HF_HUB_CACHE` (offline when not writable). Per account: recordings, config, `.env`, logs, TCC, Launch at Login.
- **Packaged app (release dmg):** Info.plist `MNPackaged`; the bundle carries the pipeline source + `uv.lock` (`Contents/Resources/pipeline`) and `uv` (`Contents/MacOS`). The first-run setup (`SetupMachine` in Core, `SetupRunner` in the app; card in the main window) builds `~/Library/Application Support/MeetingNotes/runtime/` (same layout and marker as a shared install, `"mode": "packaged"`) step by step: runtime (`uv sync --frozen --no-dev`, managed Python), `meeting-notes setup --only speech|diarization|summary --json` (stdout `{"event":"setup","step","status":"start|progress|done|error","message"?,"fraction"?}`), Ollama detect. Resumable and cancellable, `nice 10`, paused while recording or a notes job runs; after an update only the runtime step re-runs. No ffmpeg needed (macOS `afconvert` fallback). Release steps: `docs/release.md`.
- **App state:** `~/Library/Application Support/MeetingNotes/state.json`; control via `meetingnotes://` URLs or `meeting-notes ctl`.
- **Diarization helper:** `MeetingNotesDiarize <wav> --models DIR` prints one JSON line `{segments: [{start, end, speaker}], ...}`; `--prepare` downloads/compiles the models with `progress <fraction> <phase>` lines on stderr. Lookup: `fluidaudio_cli` (override) → `MEETING_NOTES_DIARIZE_CLI` (app) → `~/Applications`, `/Applications`, shared-install `app` bundles → `app/.build` → PATH. Fallback: helper missing or failing → pyannote (HF_TOKEN) → ungated clustering → VAD; `.work/diarization.json` and `transcript.json` record `engine` (what ran).

## Commands

```bash
make help        # list targets
make install     # one pass, idempotent: prerequisites, uv sync, models, build and install the app (ARGS=--dry-run)
make install-shared  # same for every account: /Applications + /Users/Shared/MeetingNotes (read-only store; docs/research/one-click-install.md)
make deps        # uv sync + swift package resolve
make dev         # deps + swift build + doctor --offline (never launches the app)
make lint        # lint-arch + app build
make lint-arch   # Python + Swift architecture checks
make test        # pytest (no e2e) + swift test
make test-e2e    # pipeline e2e
make build-app   # sign and install ~/Applications/MeetingNotes.app (+ diarization helper)
make release     # build/release/MeetingNotes-<version>.dmg + SHA256SUMS.txt (ARGS=--dry-run|--version X); never installs or publishes
make previews    # render UI PNGs (DIR=docs/screenshots)
make ci          # lint + test
make clean       # build/, app/.build, __pycache__ (never models/)
```
