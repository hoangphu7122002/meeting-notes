# AGENTS.md — meeting-notes

Local-only macOS meeting recorder: Swift/SwiftUI app (`app/`) + Python pipeline (`pipeline/`) that
transcribes, labels speakers and summarizes on the Mac. User docs: [`README.md`](README.md).

## Hard rules

1. **Local only.** No cloud APIs. Network is for model weights (Hugging Face, Ollama registry) and the HF gated-model access check.
2. **Summaries use local Ollama only** (`ollama_url`, default `127.0.0.1:11434`). Never Claude/OpenAI or any cloud LLM, for summaries or any pipeline step.
3. **Secrets never printed or committed.** `HF_TOKEN` lives only in the gitignored root `.env`; error text goes through `redact()`.
4. **Do not touch other projects.** Never start, stop or reset anything on port 55322 (banhloc Supabase DB) or other repos' stacks; stop processes by PID only.
5. **App-to-pipeline contract is frozen** unless both sides change in one commit with tests (see Contracts).
6. **Config keys and env names are public API:** `config.toml` keys, `MEETING_NOTES_*`, `HF_TOKEN`, `MN_PIPELINE_DIR`, Info.plist `MNPipelineDir`/`MNUvPath`, UserDefaults keys under `com.hoangphu.meetingnotes`.
7. **Do not move `pipeline/`, `models/` or `.env`:** the installed app and configs point at them.
8. **Build the app only with `scripts/build-app.sh`** (stable local signing identity keeps mic/screen permissions); bundle id `com.hoangphu.meetingnotes`; ad-hoc signing only when asked.
9. **Never record without a user action.** Meeting detection only offers. The worker is spawned on demand, never at launch or while recording unless the user enabled live transcription (Settings › Recording › Live transcript while recording, default off); heavy ML imports stay lazy.
10. **English for code, comments, docs.** UI copy lives in `L10n.swift` (Vietnamese default, English). Never commit `build/`, `app/.build`, `models/`, `.venv`, recordings.

## Layout

```
app/Sources/
  MeetingNotesCore/      pure logic, unit-tested: Recording/ Meetings/ Worker/ Control/ Preferences/ Presentation/
  MeetingNotesUI/        SwiftUI views + view state: State/ MainWindow/ Pill/ Notes/ Settings/ Shared/
  MeetingNotes/          executable: main.swift AppDelegate.swift Controller/ Presentation/ Capture/ Pipeline/ System/ Diagnostics/
  MeetingNotesPreviews/  offscreen PNG renderer with fake state
  MeetingNotesDiarize/   helper CLI: FluidAudio Core ML diarization of one WAV -> JSON (opt-in `diarization_engine = "fluidaudio"`)
app/Tests/               Core + UI tests
pipeline/src/meeting_notes/
  config/                settings kernel (Config, TOML + env loader, hf_token, redact)
  domain/                pure: stdlib + numpy/scipy; intervals, signal, speakers, segments, notes rules/markdown, metrics,
                         live_chunks / live_backlog / partial_merge (live transcription policy), voice_check (mic single-voice test)
  application/           use cases + ports.py (Protocols): process_meeting, summarize_meeting, transcribe_blocks, import_audio,
                         live_transcribe (live job), live_reuse (Stop-time reuse of live partials)
  adapters/outbound/     one vendor or sink per file: ffmpeg, wav, meeting folder, pyannote, sherpa-onnx + fluidaudio CLI (opt-in), mlx, ollama, hf hub, progress
  adapters/inbound/      commands.py (CLI handlers), worker.py (JSON-lines worker)
  entrypoints/           cli.py (argparse main), wiring.py (dependency factory)
pipeline/tests/          unit/{domain,application,adapters} architecture/ e2e/ · pipeline/bench/ (pipeline harness + long fixtures, diarization-only bench, asr, summary, live benches) · pipeline/scripts/ (model converter)
scripts/                 install.sh build-app.sh setup-signing.sh check-swift-arch.sh
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
- **App state:** `~/Library/Application Support/MeetingNotes/state.json`; control via `meetingnotes://` URLs or `meeting-notes ctl`.

## Commands

```bash
make help        # list targets
make install     # first-time: brew deps, uv sync, models, build and install the app
make deps        # uv sync + swift package resolve
make dev         # deps + swift build + doctor --offline (never launches the app)
make lint        # lint-arch + app build
make lint-arch   # Python + Swift architecture checks
make test        # pytest (no e2e) + swift test
make test-e2e    # pipeline e2e
make build-app   # sign and install ~/Applications/MeetingNotes.app
make previews    # render UI PNGs (DIR=docs/screenshots)
make ci          # lint + test
make clean       # build/, app/.build, __pycache__ (never models/)
```
