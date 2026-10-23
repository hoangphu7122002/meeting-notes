# Meeting Notes

A free meeting-notes app for macOS that runs entirely on your Mac. Its main window shows what it is doing: click **Start recording** (or press **⌃⌥⌘R**) when a meeting starts, and **Stop & create notes** when it ends; while recording, a small floating control at the bottom of the screen shows the timer and levels. It records your microphone and the other participants (system audio from Zoom, Google Meet, Teams and so on). It then transcribes the audio, labels the speakers and writes a summary with action items, all locally.

- **App** (`app/`, Swift/SwiftUI): records the mic and system audio as two separate tracks, using ScreenCaptureKit for system audio (no BlackHole needed). Main window (controls, meters, processing, recent meetings, permissions), optional floating pill, Dock icon and a compact menu bar icon, Vietnamese (default) or English UI (Settings › Ngôn ngữ / Language), global hotkeys, pause/resume, meeting detection, a notes viewer and a list of recent meetings.
- **Pipeline** (`pipeline/`, Python/uv): handles transcription (mlx-whisper large-v3-turbo, 4-bit, on the Apple GPU), speaker diarization (pyannote, with a fallback) and the summary (Ollama `qwen3:4b` by default, `qwen3:8b` optional). The app runs it after every recording, and you can run it yourself from the CLI.

Nothing is sent to a cloud service. The only network traffic is a one-time download of open model weights (Hugging Face, Ollama registry).

## Install

Requirements: macOS 14+ (15 recommended), Apple Silicon, Homebrew, Xcode Command Line Tools (`xcode-select --install`).

```sh
cd ~/meeting-notes
scripts/install.sh
```

The script does the following:
1. `brew install ffmpeg ollama` and `brew services start ollama`.
2. `uv sync` for the pipeline.
3. `meeting-notes setup` downloads the models: whisper turbo 4-bit (~0.44 GB), the speaker-embedding model (~30 MB), `qwen3:4b` (~2.5 GB) and pyannote if you have access.
4. Builds `MeetingNotes.app`, signs it with a local self-signed identity (created once by `scripts/setup-signing.sh`) and installs it to `~/Applications/MeetingNotes.app`.

To rebuild only the app: `scripts/build-app.sh`. To check the setup: `uv run --project pipeline meeting-notes doctor`.

### Speaker diarization (one-time, optional but recommended)

The best speaker labels come from pyannote's gated models. Your token is read from `.env` (`HF_TOKEN=...`, gitignored) in the repo root. The token is valid, but **the model terms have not been accepted yet**, so pyannote currently refuses access. To enable it:

1. Log in to Hugging Face with the account that owns the token.
2. Open **https://huggingface.co/pyannote/speaker-diarization-community-1** and accept the conditions. This is the default model.
3. Optional, for the 3.1 fallback: also accept **https://huggingface.co/pyannote/speaker-diarization-3.1** and **https://huggingface.co/pyannote/segmentation-3.0**.
4. Check with `uv run --project pipeline meeting-notes doctor`. `diarization_access` should say `ok`.

Until then the pipeline falls back automatically. It never fails because of diarization:
- **Voice clustering** (default fallback): uses the ungated `pyannote/wespeaker-voxceleb-resnet34-LM` embeddings with agglomerative clustering. It separates distinct voices well, but similar voices on one track may merge.
- **Me / Others**: if even the embedding model is unavailable, the mic track is labelled "Me" and the system track "Others".

The method used is recorded in `transcript.json` (`diarization.methods`) and noted in `notes.md`.

## First run (permissions)

1. Open `~/Applications/MeetingNotes.app`. The main window opens with a getting-started note and the permission checklist (Fix buttons and a 5 s live Me/Them test). Notifications are optional ("Notes ready"). The window opens again from the Dock icon, `open -a MeetingNotes`, `open meetingnotes://show` or the menus (Open MeetingNotes).
2. Click **Start Recording**. macOS asks for:
   - **Microphone**: click Allow.
   - **Screen & System Audio Recording**: macOS opens System Settings › Privacy & Security › Screen & System Audio Recording. Enable **MeetingNotes**, then reopen the app (the main window banner has **Relaunch**, enabled while nothing is recording or processing). Only audio is captured; no screen content is saved.
3. The first recording before step 2 is complete may be mic-only. The main window shows an orange banner and the pill a warning ("Others are not being recorded").
4. Optional: **Settings › Launch at Login**. If macOS asks for approval, enable it in System Settings › General › Login Items.

Notes:
- **Permissions survive rebuilds:** macOS ties Microphone and Screen & System Audio permissions to the code signature. `scripts/build-app.sh` signs with a fixed local certificate ("MeetingNotes Local Signing", created once by `scripts/setup-signing.sh` in its own keychain `~/Library/Keychains/meetingnotes-signing.keychain-db`, password in `~/.config/meeting-notes/signing-keychain.pass`), so the designated requirement (`identifier "com.hoangphu.meetingnotes" and certificate leaf = H"…"`) stays the same across rebuilds. Versions before this one were ad-hoc signed, so **grant the permissions once more after updating**. If a permission seems stuck, remove MeetingNotes from the list in System Settings and add it again. `CODESIGN_IDENTITY=-` forces ad-hoc signing (permissions then reset on every rebuild).
- **Monthly prompt:** macOS 15 periodically asks you to re-confirm screen/audio recording access, and shows a purple indicator while recording.

## Controls (no menu bar needed)

On a MacBook with a notch and a crowded menu bar, macOS hides menu bar items that don't fit behind the notch, with no warning. The app therefore never depends on its menu bar icon:
- **Main window**: the home of the app (Start, Pause/Resume, Stop & create notes, Discard, title, meters, processing, recent meetings, permissions).
- **Floating pill** at the bottom center, just above the Dock, on every Space including full-screen apps: shown while recording and processing (Settings › Show floating control while recording, default on; …when idle, default off). Hover it to expand. Clicking the pill only expands it; only the explicit buttons start, stop or discard. Drag it to move it (menu › Reset pill position).
- **Dock icon** (Settings › Show in Dock, default on). Right-click it for Start / Pause / Stop & create notes / Show controls / Open last notes. Opening the app again (Finder, Spotlight, `open -a MeetingNotes`) brings the main window to the front.
- **Hotkeys:** **⌃⌥⌘R** start/stop, **⌃⌥⌘P** pause/resume, each with a short on-screen toast.
- **URL scheme / CLI:** `open meetingnotes://stop` (also start, pause, resume, toggle, show), or `uv run --project ~/meeting-notes/pipeline meeting-notes ctl stop|start|pause|resume|toggle|show|status`.
- **Menu bar icon:** icon only, to take as little space as possible.

## Use

| Action | How |
|---|---|
| Start / stop recording | Pill (hover) › Start / Stop & create notes, Dock icon menu, menu bar icon, or **⌃⌥⌘R** anywhere. Start is ignored while a recording runs ("Already recording"). |
| Pause / resume | Pill › Pause / Resume or **⌃⌥⌘P**. Both captures stop (mic indicator off); paused time is not in the audio. |
| Discard | Pill › Discard (asks first; deletes that recording's folder) |
| Recording state | Pill: red dot + timer + level bars; hover for Me/Them meters and the meeting title |
| Meeting detection | When Zoom, Teams, Webex, Slack, FaceTime, Discord or a browser (Meet) starts using the mic, a card at the top right asks "Start notes?" (Start / Not now / Snooze 1 h). Never records by itself. Needs macOS 14.2+. |
| Auto-stop | After N minutes of silence (Settings, default 15) or when the meeting app releases the mic, a card offers to stop in 60 s (Stop now / Keep recording). |
| Processing | Starts after Stop (Settings › Create notes: right away / when idle and plugged in / manually). The pill shows each stage, percent and time left; "Open transcript" as soon as the transcript exists. |
| Notes | Built-in viewer (summary, decisions, action items, searchable transcript) or `notes.md` in your editor |
| Recent meetings | Menu bar icon › Recent meetings (Open notes / Show in Finder / Retry / Create notes / Show pipeline log) |
| Errors | In the pill, with one action (Retry or Open System Settings); audio is always kept |
| Scripting | `open meetingnotes://start` (stop, pause, resume, toggle, show) or `meeting-notes ctl …`; state in `~/Library/Application Support/MeetingNotes/state.json` |

Change the hotkey (then relaunch the app):

```sh
defaults write com.hoangphu.meetingnotes hotkey "cmd+shift+f5"   # modifiers: ctrl opt shift cmd; keys a-z 0-9 f1-f12 space
defaults write com.hoangphu.meetingnotes pauseHotkey "ctrl+opt+cmd+p"
```

### Where notes go

`~/MeetingNotes/<YYYY-MM-DD HHmm> <title>/` contains:

| File | Content |
|---|---|
| `notes.md` | Title, date, duration, speakers; summary, key decisions, action items (owner and due date when mentioned), open questions; then the full speaker-labelled transcript with timestamps. Written in the meeting's main language (Vietnamese or English headings). |
| `transcript.json` | Segments `{start, end, speaker, track, language, text}`, detected languages, speakers, diarization method |
| `mic.m4a`, `system.m4a`, `mixed.m4a` | Your mic, the other participants, and both mixed (aligned AAC) |
| `meeting.json` | Recording metadata (start/end, track offsets, warnings) |
| `status.json`, `pipeline.log`, `pipeline.app.log` | Processing state and logs |
| `.work/` | Intermediate results (diarization, summary) used for resuming |

Folders start as `<date> Meeting` and are renamed after the generated title. Change the notes folder in the menu (Settings › Change Notes Folder…).

### CLI

```sh
cd ~/meeting-notes/pipeline
uv run meeting-notes process "~/MeetingNotes/2026-10-19 1430 Meeting"        # resume: finished stages are skipped
uv run meeting-notes process "<folder>" --from summarize                     # redo the summary (e.g. after changing model)
uv run meeting-notes process "<folder>" --force                              # redo everything
uv run meeting-notes import ~/Downloads/call.mp3 [--title "Weekly sync"]     # notes for any audio/video file
uv run meeting-notes doctor                                                  # check ffmpeg, Ollama, models, HF access
uv run meeting-notes setup                                                   # (re)download models
uv run meeting-notes live "<copy of a folder>" --simulate 4                  # replay a recording through live transcription
```

The stages are `prepare → diarize → transcribe → summarize → render → finalize`. Each one saves its output, so a crash or a failed summary can be resumed without redoing the transcription. If Ollama is down, `notes.md` is still written with the transcript and a "Summary unavailable" note; run `process <folder>` again later to add the summary.

## How it works

- **Recording:** the mic is captured via AVAudioEngine and system audio via ScreenCaptureKit (excluding the app's own audio). Each track is written as 16-bit WAV with its host-clock start offset, so the tracks stay aligned and survive crashes.
- **Speakers:** the mic track is "Me". System audio is diarized separately, so remote participants become Speaker 1, 2, and so on.
  - **No headphones:** if the mic hears your speakers, mic activity during remote speech is treated as echo and dropped.
  - **In-person meetings:** several distinct voices on the mic get their own labels (`mic_speakers = "me"` turns this off).
  - **Single-voice mic (faster):** before the full diarization pass on the mic, a quick check (voice activity plus a few voice embeddings, remote speech left out) decides whether the mic holds only your voice. If it is sure, the full pass is skipped and your turns come from voice activity; if it is unsure or hears several voices, the full pass runs as before. `mic_voice_check = false` turns the check off.
- **Transcription:** whisper large-v3-turbo (4-bit, `mlx-community/whisper-large-v3-turbo-q4`) runs per speaker block. The language is detected per block and per turn, restricted to `languages` (default `["vi", "en"]`), so mixed Vietnamese/English meetings are transcribed in the right language turn by turn. Typical Whisper hallucinations on silence ("Hẹn gặp lại các bạn trong những video tiếp theo", "Thanks for watching") are filtered out.
- **Summary:** Ollama `qwen3:4b` by default (thinking disabled, JSON-schema output, temperature 0.2) produces the summary, decisions, action items and open questions in the main language. Long meetings (over `summary_chunk_chars`, ~20 min) are extracted part by part (`summary_extract_chars`); lines with explicit decision words, a commitment with a deadline, or a question said to be open are checked so none is lost, and the items are merged in Python rather than by the model. On a 1-hour synthetic test this raised recall of the 10 planted decisions/action items/questions from 1-2/10 to 10/10 (`pipeline/bench/summary_bench.py --long`).

## Change models

Create `~/.config/meeting-notes/config.toml` (all keys in `pipeline/config.example.toml`):

```toml
whisper_model = "mlx-community/whisper-large-v3-mlx"   # more accurate, ~2x slower ("mlx-community/whisper-large-v3-turbo" = fp16 turbo)
ollama_model  = "qwen2.5:7b"                            # run `ollama pull qwen2.5:7b` first (or let the pipeline pull it)
languages     = []                                      # allow any language
initial_prompt = "Momos, OKR, Kubernetes"               # vocabulary hint for names/terms
```

Model notes:
- **Whisper model:** the default is turbo quantized to 4 bits (`mlx-community/whisper-large-v3-turbo-q4`). In our benchmark it had the same WER as fp16 turbo on Vietnamese, English and code-switched speech, with peak GPU memory 1.24 GB instead of 2.31 GB, at ~10% slower decoding. Set `whisper_model = "mlx-community/whisper-large-v3-turbo"` for fp16 turbo.
- **Summary model:** pick it in the app (Settings › Summary model: Light `qwen3:4b` ~3.6 GB loaded / Better `qwen3:8b` ~6.3 GB loaded), or set `ollama_model`.
  - The default is 4b because on this 16 GB Mac (Cursor, Chrome and a VM open) 8b pushed free memory down to 9% and grew swap by about 6.5 GB, which made the Mac lag. 4b kept free memory at 23% or more.
  - With the deadline-preserving prompt, 4b got the action items right on the test meeting. Use 8b when the Mac is otherwise idle.
- `qwen3:14b` (~9 GB) is not recommended on 16 GB.
- After changing the summary model, re-run `process <folder> --from summarize` on old meetings if you want.

### Using PhoWhisper or your own quantized whisper (experimental)

`whisper_model` also accepts a local mlx-whisper directory (if that directory is missing, the pipeline warns and falls back to fp16 turbo). Convert a Hugging Face Whisper checkpoint (or quantize an existing mlx model) with the bundled script, then point the config at the output:

```bash
cd pipeline
uv run python scripts/convert_phowhisper.py vinai/PhoWhisper-large ../models/phowhisper-large-q8-mlx --bits 8
uv run python scripts/convert_phowhisper.py mlx-community/whisper-large-v3-turbo ../models/whisper-turbo-q4-mlx --bits 4
```

```toml
whisper_model = "/Users/you/meeting-notes/models/phowhisper-large-q8-mlx"   # or env MEETING_NOTES_WHISPER_MODEL
```

PhoWhisper is **not** the default: in our benchmark it did not beat turbo on Vietnamese and handled English and code-switched terms much worse. Turbo q4 matched fp16 quality with about half the GPU memory, so it is the default (the published `mlx-community/whisper-large-v3-turbo-q4` scored the same as our local conversion). Numbers and method: `docs/research/phowhisper-mlx.md`. Benchmark a model with `uv run python bench/asr_bench.py all <dir> new --model <path> --label <name>`.

Environment overrides: `MEETING_NOTES_OLLAMA_MODEL`, `MEETING_NOTES_WHISPER_MODEL`, `MEETING_NOTES_DIR`, `MEETING_NOTES_CONFIG`.

### Live transcript (optional, off by default)

**Settings › Recording › Live transcript while recording** shows the last lines ("Me" / "Others") in the expanded pill while you record, about 10–35 s behind. The pipeline worker then runs during the meeting: it tails `mic.wav` / `system.wav` (capture is not changed), cuts each track at pauses, transcribes one chunk at a time with the same whisper model at low priority, and appends the result to `.work/transcript.partial.jsonl`.
- **After Stop**, chunks that were cut at a natural pause and contain one speaker are reused; everything else (forced cuts, two speakers, the tail, skipped audio) is transcribed as today, so the notes are the same with or without it, only sooner. `transcript.json` gets a `live` key (`reused_sec`, `decoded_sec`).
- **Cost:** about 1.2 GB more memory while recording (whisper stays loaded into the Stop-time job) and GPU bursts of 1–5 s per chunk. It waits while memory pressure is not normal, CPU is saturated or the Mac is hot, never runs on battery unless `live_on_battery = true`, and skips audio more than `live_max_backlog_sec` behind. The pill then says the live transcript is paused; the notes stay complete.
- **Config:** `live_min_chunk_sec`, `live_max_chunk_sec`, `live_pause_sec`, `live_max_backlog_sec`, `live_on_battery` (`pipeline/config.example.toml`).
- **Live polish (off by default):** `live_polish = "rules"` makes the worker also send `live_polish` events: per paragraph (speaker change, pause ≥ `live_polish_pause_sec`, or `live_polish_max_words`), a cleaned display text that joins sentences split across chunks, capitalizes sentence starts, applies `glossary` spelling, collapses decode loops, hides pure interjections (`ờ`, `ừm`, `um`, `uh`; never `ừ`, `thì`, `kiểu` or a final `à`) and ends closed paragraphs with a period. Rules only, < 10 ms, no model; NFC output and Vietnamese tone marks are never changed. Raw partials and the transcript after Stop are untouched. In the app: **Settings › Recording › Tidy up the live transcript** (needs live transcript on; sends `"polish":"rules"` with the `live` command, overriding `config.toml` for that job, only when the worker advertises `live_polish`). The pill then shows polished paragraphs, with a "Show raw" link to switch back to the raw chunks.
- **Try it without recording:** `meeting-notes live <copy of a meeting folder> --simulate 4` replays it at 4x and writes the partials into that folder; `process` it afterwards to compare.

## Performance

The app is built to stay out of the way while you work:
- **Idle:** about 0% CPU and a few tens of MB of RAM. Nothing is loaded at launch, meeting detection is event-driven (CoreAudio listeners), and no animations run while idle.
- **Recording:** capture only, no processing during the meeting (unless you turn on the live transcript, below). Level meters update only while the pill is visible on screen.
- **Processing** runs after Stop, one meeting at a time:
  - **Priority:** nice 10 + utility QoS, with torch/BLAS threads capped at 4.
  - **Models:** whisper and pyannote are unloaded after their stage, and the worker process exits after 1 idle minute. MLX's Metal buffer cache is capped at 256 MB while transcribing (`mlx_cache_limit_mb`); uncapped, GPU memory grew to ~4 GB (model ~1.5 GB) on a 1-hour meeting.
  - **Ollama:** `keep_alive` is 1 minute and the summary model is not preloaded.
  - **Settings › Create notes:** right away (low priority) / when idle and plugged in (full speed) / manually.
  - **Config:** `priority = "background"` (macOS background QoS) is gentler still but measured ~3x slower, with 5–8x slower model loading.
- **Measured** on a 48 s synthetic two-track meeting, with the Mac otherwise busy:

| | Before (8b, normal priority, preload) | After (defaults) |
|---|---|---|
| Wall time | 59 s | 44–65 s (transcript ready at ~33–39 s) |
| Pipeline RAM (peak) | 1.6 GB | 0.75–1.1 GB |
| Ollama model loaded | 6.3 GB | 3.6 GB |
| Lowest free memory (`memory_pressure`) | 9% | 23–25% |

- **Timings:** each run records per-stage timings in `status.json` (`timings`) and in the last `pipeline.log` event, and learns per-stage speed for the ETA (`~/.cache/meeting-notes/timings.json`).

## Troubleshooting

| Symptom | Fix |
|---|---|
| Only `mic.wav`, warning "System audio not recorded" | Grant Screen & System Audio Recording to MeetingNotes, then quit and reopen the app |
| Mic track silent | System Settings › Privacy & Security › Microphone › MeetingNotes; check the input device in Sound settings |
| Hotkey does nothing | Another app owns ⌃⌥⌘R; set another with `defaults write ... hotkey` and relaunch |
| "Ollama is not reachable" | `brew services start ollama`; then menu › Reprocess |
| Summary missing / poor | `ollama list` should show the model (`qwen3:4b`); try Settings › Summary model › Better; re-run `meeting-notes process <folder> --from summarize` |
| Can't find the app's controls | The menu bar icon may be hidden by the notch: use the pill above the Dock, the Dock icon menu, ⌃⌥⌘R, or `open meetingnotes://show` |
| Mac feels slow while notes are created | Settings › Create notes › When idle and plugged in (or Manually); keep Summary model on Light |
| Permissions asked again after an update | Expected once after switching from ad-hoc to the stable local certificate; afterwards rebuilds keep them |
| Everyone is "Speaker 1" / voices merged | Accept the pyannote terms (see above), or lower `cluster_threshold` (e.g. 0.5); then `--from diarize` |
| Too many speakers | Raise `cluster_threshold` (e.g. 0.7) |
| Wrong language on short phrases | Set `languages` to the languages actually spoken; add `initial_prompt` |
| Processing failed | Menu › meeting › Show Pipeline Log, or `pipeline.log` in the folder; fix, then Reprocess |
| Launch at login needs approval | System Settings › General › Login Items › allow MeetingNotes |
| App can't find the pipeline | The app uses the paths baked in at build time (`MNPipelineDir`, `MNUvPath` in Info.plist). If you moved the repo, rebuild it. Or run `defaults write com.hoangphu.meetingnotes pipelineDir /new/path/pipeline` |

## Privacy

- Audio, transcripts and notes stay in `~/MeetingNotes`. Transcription, diarization and summarization run on this Mac.
- No cloud APIs are used. Network use is limited to downloading model weights from Hugging Face and the Ollama registry. Hugging Face also checks access to the gated pyannote model when it loads.
- Telemetry is disabled: pyannote metrics (`PYANNOTE_METRICS_ENABLED=false`) and the Hugging Face hub (`HF_HUB_DISABLE_TELEMETRY=1`).
- The Hugging Face token lives only in the gitignored `.env`. It is never logged, and error messages are redacted.
- The app shows no consent banner. Recording people may require their consent where you live, and that is your responsibility.

## Development

Rules, layout and architecture checks: [`AGENTS.md`](AGENTS.md). Shortcuts: `make help` (`deps`, `dev`, `lint`, `lint-arch`, `test`, `test-e2e`, `build-app`, `previews`, `ci`, `clean`). Underlying commands:

```sh
cd pipeline
uv run pytest                                       # unit tests (fast, no models)
MEETING_NOTES_E2E=1 uv run pytest tests/e2e/test_e2e.py # end-to-end: synthetic Vietnamese/English meeting via `say` + real models + Ollama
uv run python tests/e2e/make_synthetic.py /tmp/x    # just generate the synthetic meeting
uv run python bench/pipeline_bench.py make /tmp/fx --minutes 12   # long synthetic two-track meeting + reference turns/text
uv run python bench/pipeline_bench.py run /tmp/fx --repeat 3 [--set mic_voice_check=false] [--allow-warn]
uv run python bench/pipeline_bench.py report /tmp/fx  # medians: stage times, peak RSS, swap delta, pressure, WER, DER
cd ../app && swift build && swift test             # app debug build + unit tests (Core + UI)
swift run MeetingNotesPreviews ../docs/screenshots  # offscreen PNGs of the pill and main window (fake state; never starts the app)
~/Applications/MeetingNotes.app/Contents/MacOS/MeetingNotes --self-test-record 20 /tmp/mn-test --pause-at 6 --pause-for 5   # headless recording test
```

App ↔ pipeline contract:
- The app spawns `uv run --project pipeline meeting-notes worker` on demand (never at launch or while recording) and sends JSON-line jobs on stdin (`{"cmd":"process","job":…,"folder":…}`, `cancel`, `quit`); the worker exits after about a minute idle.
- stdout carries JSON lines tagged with the job: `stage`, `progress` (`fraction`, `overall`, `eta_sec`), `warning`, `error`, `partial`, `cancelled`, `done` (`folder`, `notes`, `title`), then `job_end` (`exit` 0 ok, 1 failed, 2 bad request, 3 cancelled).
- `meeting.json` carries `pauses` (`at_sec` in recorded time, `duration_sec` wall), `duration_sec` (recorded) and `wall_duration_sec`.
- The pipeline writes `status.json` (`state`: running | done | failed).
