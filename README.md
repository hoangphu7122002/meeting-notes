# Meeting Notes

A free meeting-notes app for macOS that runs entirely on your Mac. It lives in the menu bar: click **Start Recording** (or press **⌃⌥⌘R**) when a meeting starts and **Stop** when it ends. It records your microphone and the other participants (system audio from Zoom, Google Meet, Teams and so on). It then transcribes the audio, labels the speakers and writes a summary with action items, all locally.

- **Menu bar app** (`app/`, Swift/SwiftUI): records the mic and system audio as two separate tracks, using ScreenCaptureKit for system audio (no BlackHole needed). It also has a global hotkey, launch at login, meeting detection and a list of recent meetings.
- **Pipeline** (`pipeline/`, Python/uv): handles transcription (mlx-whisper large-v3-turbo on the Apple GPU), speaker diarization (pyannote, with a fallback) and the summary (Ollama `qwen3:8b`). The app runs it after every recording, and you can run it yourself from the CLI.

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
3. `meeting-notes setup` downloads the models: whisper turbo (~1.6 GB), the speaker-embedding model (~30 MB), `qwen3:8b` (~5.2 GB) and pyannote if you have access.
4. Builds `MeetingNotes.app` and installs it to `~/Applications/MeetingNotes.app`.

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

1. Open `~/Applications/MeetingNotes.app`. A waveform icon appears in the menu bar; there is no Dock icon. Allow **notifications** when asked; they are used for "Meeting detected" and "Notes ready".
2. Click **Start Recording**. macOS asks for:
   - **Microphone**: click Allow.
   - **Screen & System Audio Recording**: macOS opens System Settings › Privacy & Security › Screen & System Audio Recording. Enable **MeetingNotes**, then quit and reopen the app (menu › Quit Meeting Notes). Only audio is captured; no screen content is saved.
3. The first recording before step 2 is complete may be mic-only. The menu shows a warning.
4. Optional: **Settings › Launch at Login**. If macOS asks for approval, enable it in System Settings › General › Login Items.

Notes:
- **Permissions after a rebuild:** the app is ad-hoc signed, so rebuilding it (`scripts/build-app.sh`) can make macOS ask for permissions again. If a permission seems stuck, remove MeetingNotes from the list in System Settings and add it again. Signing with a stable identity (`CODESIGN_IDENTITY="My Cert" scripts/build-app.sh`) avoids this.
- **Monthly prompt:** macOS 15 periodically asks you to re-confirm screen/audio recording access, and shows a purple indicator while recording.

## Use

| Action | How |
|---|---|
| Start / stop recording | Menu bar › Start Recording / Stop Recording, or **⌃⌥⌘R** anywhere |
| Recording state | Red dot + elapsed time next to the icon |
| Meeting detection | When Zoom, Teams, Webex, Slack, FaceTime, Discord or a browser (Meet) starts using the mic, you get a notification "Meeting detected — start recording?" with a **Start recording** button. Also shown in the menu. Toggle: Settings › Detect Meetings (needs macOS 14.2+). |
| Processing | Starts automatically after Stop. The menu shows the stage and percent; you get a "Notes ready" notification when it finishes. |
| Recent meetings | The last 8 meetings in the menu, each with Open Notes / Show in Finder / Reprocess / Show Pipeline Log |
| Errors | Shown at the top of the menu (Clear Error) and as a notification |

Change the hotkey (then relaunch the app):

```sh
defaults write com.hoangphu.meetingnotes hotkey "cmd+shift+f5"   # modifiers: ctrl opt shift cmd; keys a-z 0-9 f1-f12 space
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
```

The stages are `prepare → diarize → transcribe → summarize → render → finalize`. Each one saves its output, so a crash or a failed summary can be resumed without redoing the transcription. If Ollama is down, `notes.md` is still written with the transcript and a "Summary unavailable" note; run `process <folder>` again later to add the summary.

## How it works

- **Recording:** the mic is captured via AVAudioEngine and system audio via ScreenCaptureKit (excluding the app's own audio). Each track is written as 16-bit WAV with its host-clock start offset, so the tracks stay aligned and survive crashes.
- **Speakers:** the mic track is "Me". System audio is diarized separately, so remote participants become Speaker 1, 2, and so on.
  - **No headphones:** if the mic hears your speakers, mic activity during remote speech is treated as echo and dropped.
  - **In-person meetings:** several distinct voices on the mic get their own labels (`mic_speakers = "me"` turns this off).
- **Transcription:** whisper large-v3-turbo runs per speaker block. The language is detected per block and per turn, restricted to `languages` (default `["vi", "en"]`), so mixed Vietnamese/English meetings are transcribed in the right language turn by turn. Typical Whisper hallucinations on silence ("Hẹn gặp lại các bạn trong những video tiếp theo", "Thanks for watching") are filtered out.
- **Summary:** Ollama `qwen3:8b` (thinking disabled, JSON-schema output, temperature 0.2) produces the summary, decisions, action items and open questions in the main language. Long meetings are summarized in parts and then merged.

## Change models

Create `~/.config/meeting-notes/config.toml` (all keys in `pipeline/config.example.toml`):

```toml
whisper_model = "mlx-community/whisper-large-v3-mlx"   # more accurate, ~2x slower
ollama_model  = "qwen2.5:7b"                            # run `ollama pull qwen2.5:7b` first (or let the pipeline pull it)
languages     = []                                      # allow any language
initial_prompt = "Momos, OKR, Kubernetes"               # vocabulary hint for names/terms
```

Model notes:
- This Mac has 16 GB RAM, so 7–8B models are the sweet spot.
- `qwen3:14b` (~9 GB) gives better summaries but is slower and tight on memory while other apps are open.
- After changing the summary model, re-run `process <folder> --from summarize` on old meetings if you want.

Environment overrides: `MEETING_NOTES_OLLAMA_MODEL`, `MEETING_NOTES_WHISPER_MODEL`, `MEETING_NOTES_DIR`, `MEETING_NOTES_CONFIG`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Only `mic.wav`, warning "System audio not recorded" | Grant Screen & System Audio Recording to MeetingNotes, then quit and reopen the app |
| Mic track silent | System Settings › Privacy & Security › Microphone › MeetingNotes; check the input device in Sound settings |
| Hotkey does nothing | Another app owns ⌃⌥⌘R; set another with `defaults write ... hotkey` and relaunch |
| "Ollama is not reachable" | `brew services start ollama`; then menu › Reprocess |
| Summary missing / poor | `ollama list` should show `qwen3:8b`; re-run `meeting-notes process <folder> --from summarize` |
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

```sh
cd pipeline
uv run pytest                                       # unit tests (fast, no models)
MEETING_NOTES_E2E=1 uv run pytest tests/test_e2e.py # end-to-end: synthetic Vietnamese/English meeting via `say` + real models + Ollama
uv run python tests/e2e/make_synthetic.py /tmp/x    # just generate the synthetic meeting
cd ../app && swift build                            # app debug build
~/Applications/MeetingNotes.app/Contents/MacOS/MeetingNotes --self-test-record 5 /tmp/mn-test   # headless recording test
```

App ↔ pipeline contract:
- The app runs `uv run --project pipeline meeting-notes process <folder> --json`.
- stdout carries JSON lines: `stage`, `progress` (`fraction`, `overall`), `warning`, `error` and `done` (`folder`, `notes`, `title`).
- The exit code is 0 on success.
- The pipeline writes `status.json` (`state`: running | done | failed).
