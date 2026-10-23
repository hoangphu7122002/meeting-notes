# Meeting Notes

Local-only macOS meeting recorder. It records your mic and the other participants (system audio via ScreenCaptureKit), transcribes with mlx-whisper, labels speakers, and writes a summary with decisions and action items using a local Ollama model. Nothing leaves the Mac: the only network traffic is downloading open model weights (Hugging Face, Ollama registry).

- **App** (`app/`, Swift/SwiftUI): recording, floating pill, Dock/menu bar icons, hotkeys, notes viewer. Vietnamese (default) or English UI.
- **Pipeline** (`pipeline/`, Python/uv): transcription, diarization, summary. Runs after each recording; also usable from the CLI.

## Requirements

macOS 14+ (15 recommended), Apple Silicon, Xcode Command Line Tools (`xcode-select --install`). No Hugging Face account.

## Install and build

```sh
cd ~/meeting-notes
make install      # one pass, safe to re-run: Homebrew/uv/ffmpeg/Ollama if missing, uv sync, models, app
make install ARGS=--dry-run   # print the plan and commands, change nothing
make build-app    # rebuild only the app; quits an idle MeetingNotes first (never one that records, unless --force)
uv run --project pipeline meeting-notes doctor   # check ffmpeg, Ollama, models, diarization helper
```

**Several macOS accounts on one Mac:** `make install-shared` (`ARGS=--dry-run` first) installs the app to `/Applications` and the pipeline + models once in `/Users/Shared/MeetingNotes` (read-only for other accounts); each other account then runs `/Users/Shared/MeetingNotes/bin/meeting-notes-user-setup --open` and grants its own permissions. Recordings, config and permissions stay per account. Details: [one-click-install § Shared install](docs/research/one-click-install.md#shared-install-several-macos-accounts).

The app is signed with a stable local certificate (`scripts/setup-signing.sh`), so Microphone and Screen & System Audio permissions survive rebuilds. Build only via `make build-app` / `scripts/build-app.sh`.

### Speaker diarization

- **FluidAudio** (default, no token): [FluidAudio](https://github.com/FluidInference/FluidAudio)'s Core ML port of pyannote community-1 on the Neural Engine, via the `MeetingNotesDiarize` helper bundled in the app. Its ~21 MB of weights (CC-BY-4.0: pyannote, WeSpeaker, BUT Speech@FIT, converted by Fluid Inference) download on first use (`make install` prefetches them).
- **Fallback:** if the helper is missing or fails, pyannote runs (needs `HF_TOKEN` in the gitignored root `.env` or `~/.config/meeting-notes/.env` and accepted terms for `pyannote/speaker-diarization-community-1`), else voice clustering, then Me / Others. Diarization never fails the run. The engine used is saved in `transcript.json` (`diarization.engine`, `diarization.methods`).
- **Other engines:** `diarization_engine = "pyannote"` or `"sherpa-onnx"` (`cd pipeline && uv sync --extra sherpa`). Details: [diarization-alternatives](docs/research/diarization-alternatives.md).

## First run

1. Open `~/Applications/MeetingNotes.app` and click **Start recording**.
2. Allow **Microphone**, then enable **MeetingNotes** in System Settings › Privacy & Security › Screen & System Audio Recording and relaunch the app. Only audio is captured; no screen content is saved.
3. Until the second permission is granted, recordings may be mic-only (the app shows a warning).
4. Optional: Settings › Launch at Login.

macOS 15 asks periodically to re-confirm screen/audio access and shows a purple indicator while recording.

## Usage

- **Start / stop:** ⌃⌥⌘R, the floating pill, Dock icon menu, or menu bar icon. **Pause / resume:** ⌃⌥⌘P. Nothing records without a user action; meeting detection only offers to start.
- **Scripting:** `open meetingnotes://start` (also stop, pause, resume, toggle, show) or `meeting-notes ctl start|stop|pause|resume|toggle|show|status`.
- **Notes** land in `~/MeetingNotes/<YYYY-MM-DD HHmm> <title>/`: `notes.md` (summary, decisions, action items, transcript), `transcript.json`, `mic.m4a` / `system.m4a` / `mixed.m4a`, `meeting.json`, `status.json`, `pipeline.log`. Audio is kept on errors.
- **CLI** (run from `pipeline/`):

```sh
uv run meeting-notes process "<folder>" [--from summarize | --force]   # resume / redo stages
uv run meeting-notes import ~/Downloads/call.mp3 [--title "Weekly sync"]
uv run meeting-notes setup                                             # (re)download models
```

Stages: `prepare → diarize → transcribe → summarize → render → finalize`. If Ollama is down, `notes.md` is still written without a summary; rerun `process` later.

## Configuration

Optional `~/.config/meeting-notes/config.toml` (or `MEETING_NOTES_CONFIG`). All keys: [`pipeline/config.example.toml`](pipeline/config.example.toml).

| Key | Default | Purpose |
|---|---|---|
| `whisper_model` | `mlx-community/whisper-large-v3-turbo-q4` | ASR model (HF id or local mlx dir) |
| `ollama_model` | `qwen3:4b` | Summary model (`qwen3:8b` is better, ~2x RAM) |
| `languages` | `["vi", "en"]` | Allowed languages (`[]` = any) |
| `initial_prompt` | `""` | Vocabulary hint for names and terms |
| `diarization_engine` | `"fluidaudio"` | `fluidaudio` \| `pyannote` \| `sherpa-onnx` |
| `mic_voice_check` | `true` | Skip full mic diarization when the mic holds only your voice |
| `keep_models_warm` | `"auto"` | Keep models loaded between stages only under normal memory pressure (`false` / `true` also accepted) |
| `live_polish` | `"off"` | `"rules"` = display-only cleanup of the live transcript |
| `priority` | `"low"` | `low` \| `background` \| `normal` |

Live transcript (off by default; Settings › Recording › Live transcript while recording): shows the last lines while you record and reuses them after Stop; notes are the same, only sooner. It adds ~1.2 GB RAM, pauses under memory pressure and on battery (`live_on_battery`), and never changes capture. Tuning keys: `live_*` in the example config. Design: [realtime](docs/research/realtime.md), [live-polish](docs/research/live-polish.md).

Env overrides: `MEETING_NOTES_OLLAMA_MODEL`, `MEETING_NOTES_WHISPER_MODEL`, `MEETING_NOTES_DIR`, `MEETING_NOTES_CONFIG`. Model choice and benchmarks: [phowhisper-mlx](docs/research/phowhisper-mlx.md), [speed-memory](docs/research/speed-memory.md).

## Troubleshooting

| Symptom | Fix |
|---|---|
| "System audio not recorded" / mic-only | Grant Screen & System Audio Recording, then reopen the app |
| Mic track silent | System Settings › Privacy & Security › Microphone; check the input device |
| Hotkey does nothing | Another app owns it: `defaults write com.hoangphu.meetingnotes hotkey "cmd+shift+f5"`, relaunch |
| "Ollama is not reachable" | `brew services start ollama`, then Reprocess |
| Summary missing or poor | `ollama list` shows the model; try Settings › Summary model › Better; `process <folder> --from summarize` |
| Voices merged / too many speakers | Accept the pyannote terms, or tune `cluster_threshold` (lower splits more), then `--from diarize` |
| Controls not visible | The notch may hide the menu bar icon: use the pill, Dock menu, ⌃⌥⌘R or `open meetingnotes://show` |
| App cannot find the pipeline | Repo moved: rebuild, or `defaults write com.hoangphu.meetingnotes pipelineDir /new/path/pipeline` |
| Processing failed | Check `pipeline.log` in the meeting folder, fix, then Reprocess |

## Privacy

- Audio, transcripts and notes stay in `~/MeetingNotes`. Transcription, diarization and summarization run on this Mac.
- No cloud APIs. Network use is limited to downloading model weights (Hugging Face, Ollama registry); Hugging Face also checks access to the gated pyannote model when it loads.
- Telemetry is disabled (`PYANNOTE_METRICS_ENABLED=false`, `HF_HUB_DISABLE_TELEMETRY=1`).
- The Hugging Face token lives only in the gitignored `.env`; it is never logged and errors are redacted.
- The app shows no consent banner. Recording people may require their consent where you live; that is your responsibility.

## Development

Rules, layout, contracts: [`AGENTS.md`](AGENTS.md).

```sh
make lint        # architecture checks + app build
make lint-arch   # Python + Swift architecture rules only
make test        # pipeline pytest (no e2e) + swift test
make test-e2e    # pipeline end-to-end (real models + Ollama)
make help        # all targets
```

Bench harness (from `pipeline/`; use a scratch dir, never `~/MeetingNotes`):

```sh
uv run python bench/pipeline_bench.py make /tmp/fx --minutes 12
uv run python bench/pipeline_bench.py run /tmp/fx --repeat 3 [--set mic_voice_check=false]
uv run python bench/pipeline_bench.py report /tmp/fx
uv run python bench/diar_bench.py run /tmp/fx --engine sherpa-onnx   # diarization only
uv run python bench/asr_bench.py all <dir> new --model <path> --label <name>
```

## Docs

- Plans: [optimization-plan](docs/plans/optimization-plan.md)
- Research: [diarization-alternatives](docs/research/diarization-alternatives.md), [live-polish](docs/research/live-polish.md), [native-backend](docs/research/native-backend.md), [one-click-install](docs/research/one-click-install.md), [phowhisper-mlx](docs/research/phowhisper-mlx.md), [realtime](docs/research/realtime.md), [realtime-feasibility](docs/research/realtime-feasibility.md), [speed-memory](docs/research/speed-memory.md)
- UX: [ux-research](docs/ux-research.md)
