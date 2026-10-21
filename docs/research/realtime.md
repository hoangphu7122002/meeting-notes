# Real-time transcription: design study

Date: 2026-10-21. Status: design A implemented as an opt-in setting (default off), with the amendments of
[`realtime-feasibility.md`](realtime-feasibility.md) section 8 (strict reuse rule, voiced/bleed gate, warm-up); B and C not built. Machine: M1 Pro, 16 GB, macOS 15.5 (Apple
SpeechAnalyzer needs macOS 26, so it is out for now). Meetings: Vietnamese with English code-switching.
Default ASR: `mlx-community/whisper-large-v3-turbo-q4`.
Inputs: web research notes (sources in section 6), [`speed-memory.md`](speed-memory.md),
[`phowhisper-mlx.md`](phowhisper-mlx.md), the current code. Labels as in those docs: **[V]** vendor claim,
**[I]** independent/peer-reviewed, **[B]** blog or single run, **[local]** measured here. Every external
number is a claim until we reproduce it on this Mac.

## 1. Why, and under which constraints

What live ASR would buy, ranked by value for a recorder:

1. **Shorter wait after Stop.** Today all ASR runs after the meeting (`prepare → diarize → transcribe →
   summarize → render → finalize`). Turbo q4 runs at RTF ~0.18 of speech [local, synthetic], so a 1 h
   meeting spends minutes in `transcribe` alone. If speech is transcribed while it happens, only the tail,
   diarization and the summary remain.
2. **Live search / glance-back.** "What did they say about the deadline?" needs text within 10-30 s, not
   word-level latency.
3. **Live captions.** Useful for non-native listening, least needed for a recorder. Needs < 2 s latency,
   which only true streaming gives.

Constraints:

- **No lag in Zoom/Meet.** The call owns CPU/GPU (video encode/decode, blur, noise suppression). MLX ASR
  uses the GPU. Contention on an M1 Pro with a call running is **unmeasured** [gap]; it is the main risk.
- **Never disturb capture.** `TrackWriter` must keep writing; dropped buffers are data loss.
- **Local only** (AGENTS.md rules 1-2). No cloud ASR; Granola-style cloud streaming is out [V].
- **Vietnamese + English terms.** Only Whisper-family and small vi-only models cover Vietnamese; Parakeet,
  Kyutai and Voxtral Realtime do not [V]. Whisper Tiny/base are unusable on vi (WER ~92-101) [I-ish,
  Moonshine paper]. Turbo keeps English term spelling where vi-tuned models phoneticize it [local].
- **Memory.** Turbo q4 peaks at 1.24 GB MLX [local]; the earlier 4 GB peak plus swap was the bottleneck.
- **Rule 9 conflict.** AGENTS.md says the worker is never spawned while recording. Any design here needs an
  explicit opt-in setting and an amended rule ("...unless the user enabled live transcription").

## 2. How the app works today (relevant parts)

- `RecordingSession` (`app/Sources/MeetingNotes/Capture/`) runs `MicRecorder` (AVAudioEngine tap) and
  `SystemAudioCapture` (ScreenCaptureKit, 48 kHz mono, own process excluded). Each feeds a `TrackWriter`
  (`MeetingNotesCore/Recording/TrackWriter.swift`, an `AudioSink`) that writes 16-bit mono WAV
  (`mic.wav`, `system.wav`) on its own serial queue, positioned in recorded time by `RecordingClock`
  (pauses excluded, gaps filled with silence). `meeting.json` is rewritten ~3 s after start with track
  start offsets, so a crash still leaves usable offsets.
- `JobQueue` owns the only `WorkerClient`, which spawns `uv run meeting-notes worker` and speaks JSON lines
  (`WorkerEvent.swift` ↔ `adapters/inbound/worker.py` + `adapters/outbound/progress_reporter.py`). Jobs
  never start while `recordingActive`; the worker exits after `worker_idle_release_min` (1 min) idle.
- Unknown events already parse to `WorkerEvent.other`; unknown commands get
  `{"event":"worker","status":"error"}`. Both make additive protocol changes safe.
- `stage_transcribe` builds blocks from diarization turns, then `transcribe_blocks` runs VAD
  (`speech_spans`), per-block language detection limited to vi/en, and the glossary prompt. Blocks are
  capped at `whisper_max_chunk_sec` = 28 s. Two tracks: `mic` speakers resolve to "Me" (or several voices
  when `mic_speakers = "auto"`), `system` to pyannote clusters; `bleed_ratio` drops mic speech that is
  really speaker leakage.

## 3. Three designs

### A. Incremental final-quality ASR per VAD chunk (same model, low priority)

```
 mic.wav ──┐ (TrackWriter, unchanged)        worker (nice 10, utility QoS, one chunk at a time)
 system.wav┘──tail──> chunker ──> bounded queue ──> turbo q4 ──> transcript.partial.jsonl
                    (cut at pauses   (skip/defer      (mlx)       └─> live_segment event ──> pill
                     >= 0.7 s,        under load)                     ("Me" = mic, "Others" = system)
                     4-28 s)
 Stop ─> prepare ─> diarize (pyannote, offline) ─> transcribe: reuse partials + decode gaps/tail
        ─> summarize ─> render ─> finalize
```

- Pros: no new engine or dependency; the model is the verified one (vi + English terms), so live text
  **is** final text (no draft/final mismatch); each chunk ≤ 28 s keeps the glossary prompt in its window;
  biggest cut in post-Stop wait; crash-safe by construction (append-only file + offline fallback).
- Cons: latency is chunk length + decode (≈ 10-35 s), so no real captions; GPU bursts during the call
  (≈ RTF 0.18 × speech seconds, about 15-20 % GPU duty for continuous speech on two tracks, estimate);
  per-chunk language detection lacks the per-speaker prior the offline pass has.
- Resources: +1.24 GB MLX peak while recording [local]; GPU bursts of ~1-5 s per chunk; CPU small.
- Risks: call stutter from GPU contention (test T2); errors at forced cuts (T3); system-track segments that
  span two remote speakers need re-decoding at Stop (T4).

### B. Live captions with WhisperKit on the Neural Engine + final offline pass

```
 capture ──> TrackWriter (WAV, unchanged)
        └──> TeeSink ──16 kHz PCM ring buffer──> caption helper (Swift, WhisperKit, Core ML/ANE)
                                                   └─> hypothesis + confirmed text ──> caption view
 Stop ─> existing offline pipeline (or A's partials) ─> final transcript
```

- Pros: true streaming; vendor reports ~0.45 s per-word hypothesis and ~1.7 s confirmed text with turbo on
  ANE [V, WhisperKit paper, M3 Max, English]; ANE decoder step 0.3 W vs 1.5 W [V], so the GPU stays mostly
  free for the call in principle.
- Cons: second engine and model format (Core ML) to maintain; Vietnamese and code-switch quality of the
  streaming/compressed encoder is **untested** (paper reports up to +1.3 / +2.08 WER on English for
  compressed variants [V]); the paper's streaming algorithm ships in the commercial Pro SDK, while what the
  MIT open-source WhisperKit exposes for streaming must be checked [gap]; +0.6-1.6 GB RAM [V]; does not
  shorten the post-Stop wait on its own.
- Resources: ANE (Zoom may also use it for blur/noise models, unknown [gap]), small CPU for mel/feeding.
- Risks: ANE contention, draft text differing from final text (user confusion), Core ML compile time on
  first run, app-bundle size.

### C. MLX streaming Whisper (WhisperLiveKit / SimulStreaming)

```
 capture ──> TrackWriter ──> per-track 16 kHz stream ──> WhisperLiveKit (Python, MLX, turbo q4)
                                                          AlignAtt or LocalAgreement policy
                                                          └─> partial + committed words ──> UI
 Stop ─> offline pass as final (optionally skip committed spans)
```

- Pros: free/OSS, Python (same venv), real partial words from the same model family; AlignAtt latency
  ~1-2× chunk length [I, Simul-Whisper]; SimulStreaming is the maintained successor of
  whisper_streaming [I].
- Cons: continuous GPU load (the decoder re-runs on every update, worse than A's bursts); two tracks = two
  streams; no Vietnamese or code-switch numbers published [gap]; WhisperLiveKit's MLX speed figure is
  English `base.en` [V]; a new server dependency in the worker.
- Risks: highest contention of the three; stability of partial hypotheses on code-switched speech unknown.

| | A chunked final | B WhisperKit captions | C MLX streaming |
|---|---|---|---|
| Latency | 10-35 s | ~0.5-2 s [V] | ~1-2× chunk [I] |
| Final-quality live text | yes | no (draft) | no (draft) |
| Post-Stop wait | much shorter | unchanged | shorter if committed text reused |
| Main compute | GPU bursts | ANE | GPU continuous |
| New dependencies | none | WhisperKit + Swift helper | WhisperLiveKit |
| vi quality evidence | measured [local] | none | none |

## 4. Recommendation

**Build A first** behind an opt-in setting, then add **B as a caption layer** only if T1 and T2 pass. C is
not pursued: it costs more GPU than A and gives a draft, not final text. A delivers the highest-value item
(short wait, searchable text) with no new engine; B can later sit on top of A without changing it.

### 4.1 Pipeline mapping (A)

Decision: the worker **tails the growing WAV files**; Swift capture is not touched. (Rejected: a Swift-side
chunker writing chunk files; it puts VAD and file I/O next to capture and grows the app-pipeline contract.)

Domain (pure, numpy/scipy only):
- `domain/live_chunks.py`: `ChunkPolicy` (`min_sec` 4, `max_sec` 28, `pause_sec` 0.7, `pad_sec` 0.25),
  `LiveChunk(track, seq, start, end)`, `next_cut(frame_db, threshold_db, policy) -> int | None` (cut in the
  first pause ≥ `pause_sec` after `min_sec`; at `max_sec` cut at the lowest-energy frame), reusing
  `signal.frame_db` / `speech_threshold_db`.
- `domain/live_backlog.py`: `LoadSample(memory_pressure, cpu_busy, thermal, on_battery)`,
  `decide(backlog_sec, load, policy) -> Process | Defer | Skip`. Defer = keep in queue; Skip = leave the
  span for the Stop-time pass (never lost, just not live).
- `domain/partial_merge.py`: `merge_partials(turns, partials, me_name) -> (segments, uncovered)`; assigns
  each partial segment the diarization speaker with max overlap, drops mic segments outside the resolved
  mic turns (bleed rule), and returns ambiguous spans (minority speaker > 30 % of a segment) as uncovered
  intervals via `intervals.subtract`.

Application:
- `application/live_transcribe.py`: `LiveTranscription.run(stop_event)`: poll sources → cut chunks → ask
  `decide` → VAD (`speech_spans`) → `detect_language` + `choose_language` with a per-track prior →
  `transcriber.transcribe` → filters (`keep_segment`, `is_hallucination`, `collapse_repeats`, shared with
  `transcribe_blocks`) → `store.append` → `reporter.live_segment`. On stop: finish the current chunk,
  drop the queue (Stop-time pass covers it).
- `ports.py` additions: `LiveAudioSource` (`poll(track) -> (start_sec, samples_16k)`, `position(track)`),
  `PartialTranscriptStore` (`load() -> list[PartialChunk]`, `append(chunk)`, `signature`), `LoadProbe`
  (`sample() -> LoadSample`), and `ProgressReporter.live_segment(...)` / `live_status(...)`.
- `process_meeting.stage_transcribe`: unless `transcribe` is forced, load partials whose `signature`
  (whisper_model, languages, glossary/initial_prompt hash, VAD settings) matches the config; call
  `merge_partials`; run the existing `transcribe_blocks` only on blocks clipped to `uncovered` (tail,
  skipped/deferred spans, ambiguous spans). `transcript.json` gains an additive
  `"live": {"reused_sec", "decoded_sec"}` key. `finalize` deletes the partial file unless `keep_wav`.

Adapters (outbound, lazy heavy imports):
- `live_wav_reader.py`: tails `mic.wav` / `system.wav`, parses RIFF chunks to find `data` (Core Audio may
  add padding chunks such as `FLLR`; the header size is stale until close, so read to EOF in whole
  frames), resamples to 16 kHz (`resample_poly`), maps file position to recorded time with the track
  `start_offset_sec` from the provisional `meeting.json`.
- `partial_transcript_store.py`: `.work/transcript.partial.jsonl`, one line per chunk
  `{"v":1,"track","seq","start","end","language","signature","segments":[{start,end,text}]}`, append +
  `fsync`; a truncated last line is ignored on load.
- `load_probe.py`: `kern.memorystatus_vm_pressure_level` (sysctl via ctypes), `os.getloadavg`, thermal
  state; `system_resources.apply_priority("low")` stays as today.
- `model_cache.Models`: keep the transcriber loaded from the live job into the Stop-time job (no reload).

Inbound / entrypoints:
- `worker.py`: new command `{"cmd":"live","job","folder"}` runs `LiveTranscription` as a long job in the
  existing serial loop (no second thread touching models); `{"cmd":"live_stop","job"}` is handled in the
  stdin thread like `cancel` (sets a stop event). Live ends with the usual `job_end`. Idle exit cannot
  trigger during a live job.
- `cli.py`: `meeting-notes live <folder> [--simulate <speed>]` replays a finished recording in real time
  for tests and benchmarks (T2-T4) without the app.
- New config keys (public API once shipped): `live_min_chunk_sec`, `live_max_chunk_sec`,
  `live_pause_sec`, `live_max_backlog_sec` (default 120), `live_on_battery` (default false).

### 4.2 Worker protocol additions (backwards compatible)

| Direction | Message | Old peer behavior |
|---|---|---|
| stdout | `{"event":"worker","status":"ready","pid",...,"features":["live"]}` | extra key ignored |
| stdin | `{"cmd":"live","job":"live-<id>","folder":"..."}` | old worker: `status:error` → app hides live |
| stdin | `{"cmd":"live_stop","job":"live-<id>"}` | never sent unless `features` has `live` |
| stdout | `{"event":"live_segment","job","track":"mic|system","speaker":"Me|Others","seq","start","end","language","text"}` | old app: `.other` |
| stdout | `{"event":"live_status","job","state":"running|throttled|deferred|stopped","backlog_sec","skipped_sec","rtf"}` | old app: `.other` |

Both sides change in one commit with tests (rule 5): `pipeline/tests/unit/adapters` for the worker and
reporter, `app/Tests/MeetingNotesCoreTests/WorkerEventTests.swift` for parsing.

### 4.3 Swift changes

- `MeetingNotesCore/Worker/WorkerEvent.swift`: cases `.liveSegment(job:, LiveSegment)` and
  `.liveStatus(job:, LiveStatus)`; `Command.live(job:folder:)`, `Command.liveStop(job:)`.
- `MeetingNotesCore/Meetings/LiveTranscript.swift` (new, pure): ordered segments keyed by `(track, seq)`,
  dedupe, last-N lines, search; unit-tested.
- `MeetingNotes/Pipeline/WorkerClient.swift`: unchanged API, but owned by `AppController` and shared:
  `JobQueue` and a new `MeetingNotes/Pipeline/LiveTranscriber.swift` both take it; events are routed by the
  `live-` job prefix. `JobQueue` keeps "no `process` job while recording".
- `MeetingNotes/Controller/AppController+Live.swift` (new; keeps files ≤ 300 lines): start live ~3 s after
  `RecordingSession.start` (provisional `meeting.json` exists) when `Settings.liveTranscription` is on,
  on AC power or `live_on_battery`; on `finishRecording` send `live_stop` before `jobs.enqueue`, so the
  same warm worker runs the Stop-time job. Pause needs no command (files stop growing).
- `MeetingNotesUI`: `Settings/Settings.swift` key `liveTranscription` (UserDefaults, default off) + toggle
  in `SettingsView.swift`; `Pill/LiveTranscriptView.swift` (last lines, "Me"/"Others") inside
  `ExpandedCard`; L10n strings in `L10n.swift`; a preview fixture in `MeetingNotesPreviews/Fixtures.swift`.
- Capture files (`RecordingSession`, `TrackWriter`, `MicRecorder`, `SystemAudioCapture`): **no change**
  for A. B later adds a `TeeSink` (Core, an `AudioSink` fan-out) and a caption helper target.

### 4.4 Resume and crash safety

- Worker crash: the app respawns it and resends `live`; the use case resumes each track at the last
  `end` in the partial file. Audio is safe in the WAVs regardless.
- App crash: partial lines remain; the next `process` job reuses them if the signature matches.
- Config change mid-meeting (model, glossary): signature mismatch → those chunks are re-decoded at Stop.
- `--force` / `from=transcribe`: ignores partials (full offline pass, today's behavior).

### 4.5 Back-pressure (never block capture)

- Capture is decoupled by the file system: Swift only writes WAVs and sends two JSON lines.
- One chunk in flight, `nice 10` + utility QoS, `mlx_cache_limit_mb` as today.
- `decide()` defers while memory pressure is not normal, CPU is saturated or thermal state is serious;
  backlog beyond `live_max_backlog_sec` is skipped (oldest first) and left to the Stop-time pass;
  `live_status` reports `throttled` so the UI can say "live paused, notes still complete".
- Mic chunks that coincide with system speech under high `bleed_ratio` are skipped live (echo duplicates).

## 5. Feasibility tests (run before building)

Corpus: three consented real meetings (vi-heavy, en, code-switched), 10 min excerpts with corrected
reference transcripts, as planned in `speed-memory.md` section 5. Metrics via `pipeline/bench`
(NFC, lowercased, punctuation stripped; term recall on the glossary).

| # | Test | How | Pass criteria |
|---|---|---|---|
| T1 | WhisperKit vi + code-switch quality (gates B) | WhisperKit OSS turbo (Core ML) streaming and file mode vs mlx turbo q4 offline on the corpus | streaming vi WER ≤ offline + 5 pp abs; code-switch term recall ≥ 0.7; confirmed-text latency p90 ≤ 3 s on M1 Pro |
| T2 | Load during a real call (gates A and B) | 30 min Zoom and Meet calls with camera on; `meeting-notes live --simulate 1x` on a prior recording vs idle baseline; `powermetrics` (CPU/GPU/ANE), `memory_pressure`, `vm_stat` swap, Zoom statistics panel, `TrackWriter.droppedBuffers` | no audible glitch or video FPS drop > 10 % vs baseline; pressure stays normal; swap growth < 500 MB; dropped buffers unchanged; backlog median < 30 s, max < 120 s; skipped < 5 % of speech |
| T3 | Chunk-boundary errors (gates A) | per-chunk decode (policy above) vs current block decode on the same audio | WER delta ≤ 1 pp abs; term recall drop ≤ 0.05; forced cuts < 5 % of chunks; live language matches offline on ≥ 95 % of speech seconds |
| T4 | Stop-time reuse (gates A) | full `process` with and without partials | ambiguous (re-decoded) system speech < 15 %; final WER within 0.5 pp of no-reuse run; post-Stop wall time for 1 h ≤ 50 % of today |
| T5 | Apple SpeechTranscriber (later) | on macOS 26 only: print `SpeechTranscriber.supportedLocales`, test vi_VN on 2 min | informational; revisit B if vi is supported |

Results of T3 and T4 (offline replay, provisional): [`realtime-feasibility.md`](realtime-feasibility.md).

Order: T3 and T4 need no call (cheap, offline replay); T2 decides whether A can run during calls at all;
T1 only if captions are still wanted after A ships.

## 6. Open questions

- Does Zoom/Meet on this M1 Pro use the ANE (blur, noise suppression), and how much GPU headroom is left
  with camera on? (T2; no published data [gap].)
- Is per-chunk language detection with a per-track prior good enough for short code-switched turns, or
  should live chunks carry the previous chunk's language as a stronger prior?
- Should the previous chunk's text be passed as prompt context? `condition_on_previous_text` is off today
  because it causes repeat loops.
- Diarize the system track incrementally (FluidAudio streaming: 10-15 % worse DER than offline [V]) or
  keep pyannote offline only? Offline-only keeps quality; it is now the largest post-Stop stage.
- Does the open-source WhisperKit expose LocalAgreement streaming, or only the Pro SDK, and is the Pro
  license acceptable? [gap]
- In-person meetings (`mic_speakers = "auto"`, several voices on the mic): live "Me" is wrong until the
  offline pass; label it "Room"?
- Default for battery: never run live on battery, or allow at `background` priority?
- Live action items: a keyword rule is cheap; Ollama during a call would compete with ASR and the call
  (not proposed).

Sources (accessed 2026-10-21): WhisperKit paper https://arxiv.org/html/2507.10860v1 ; Argmax real-time
docs https://app.argmaxinc.com/docs/examples/real-time-transcription ; Simul-Whisper/AlignAtt
https://arxiv.org/pdf/2406.10052 ; CUNI SimulStreaming (IWSLT 2025) https://arxiv.org/html/2506.17077v1 ;
WhisperLiveKit README https://cdn.jsdelivr.net/gh/quentinfuxa/whisperlivekit@main/README.md ; whisper.cpp
stream https://huggingface.co/datasets/echodict/whisper.cpp/blob/main/examples/stream/README.md and
streaming paper https://arxiv.org/pdf/2412.11272 ; Moonshine vi https://arxiv.org/html/2509.02523v1 ;
FluidAudio benchmarks https://docs.fluidinference.com/reference/benchmarks ; Kyutai https://kyutai.org/stt ;
Voxtral Realtime https://recipes.vllm.ai/mistralai/Voxtral-Mini-4B-Realtime-2602 ; Apple SpeechTranscriber
https://developer.apple.com/documentation/speech/speechtranscriber.md ; Granola https://granola.ai/security ;
Meetily https://github.com/Zackriya-Solutions/meeting-minutes .
