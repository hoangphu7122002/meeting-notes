# Optimization plan: speed after Stop, RAM, live transcription, one-click install

Date: 2026-10-23. Status: **W1 done, W2 started**: Phase 0 harness (0.1, 0.2a synthetic fixtures, 0.4 run labels),
1.1 mic-track skip, the long-block hallucination fix and 1.2 single encoder pass are built; baseline under "normal"
pressure, real fixtures (0.2b), `diar_bench` (0.3), the baseline report (0.5) and 2.x are open. Results: section 7. Machine: M1 Pro, 16 GB, macOS 15.5, memory pressure
usually "warn" with 16-20 GB swap. Inputs: [`native-backend.md`](../research/native-backend.md),
[`diarization-alternatives.md`](../research/diarization-alternatives.md),
[`one-click-install.md`](../research/one-click-install.md), [`live-polish.md`](../research/live-polish.md),
[`realtime.md`](../research/realtime.md), [`realtime-feasibility.md`](../research/realtime-feasibility.md),
[`speed-memory.md`](../research/speed-memory.md) and the code under `pipeline/`.

Labels: **[local]** measured on this Mac, **[V]** vendor claim, **[B]** blog or single run, **[est]** estimate from
code reading. Every gain below is an estimate until Phase 0 measures it.

Settled: **no Go/Rust rewrite** (expected gain 1-5 %, see `native-backend.md` section 1). The levers are which
engine, which algorithm, and how memory is used.

---

## 0. Primer: how the pipeline spends time, and why

After Stop, `application/process_meeting.py` runs six stages in order. For a 1 h two-track meeting (mic = you,
system = everyone else), today's learned timings are:

```
prepare     54 s   3 %  ffmpeg decodes both tracks to 16 kHz WAV and encodes 3 m4a listening copies
diarize    899 s  50 %  pyannote community-1 on PyTorch MPS, run on BOTH tracks in full
transcribe 733 s  41 %  mlx-whisper turbo q4, one call per speaker block (<= 28 s)
summarize  105 s   6 %  Ollama qwen3:4b
render+finalize <1 s
total     1792 s ≈ 30 min
```

Source: EMA stage factors in `~/.cache/meeting-notes/timings.json` (`adapters/outbound/speed_history.py`),
learned from 40-290 s meetings under "warn" pressure and extrapolated to 1 h (`realtime-feasibility.md` section 5).
They likely overstate diarize/transcribe (fixed load costs amortized over short audio) and understate summarize.
That is why Phase 0 comes first.

Why each stage costs what it does:

- **Diarize (50 %).** pyannote slides a 10 s window with a 1 s step, so every second of audio is analysed ~10
  times, then runs a speaker-embedding network per window and clusters. Cost grows with *audio length*, not
  speech. `application/diarize_tracks.py` diarizes the mic track in full even though it usually holds one voice
  (you), so roughly half of this stage answers a question we mostly already know. Priority is `nice 10`, 4 threads,
  batch 8: deliberately gentle, so it runs at ~4x real time instead of the vendor's 20-25x [V].
- **Transcribe (41 %).** Whisper always encodes a padded 30 s window, even for a 3 s block. Per block we pay that
  encoder **at least twice**: `Transcriber.detect_language()` (`adapters/outbound/mlx_transcriber.py`) encodes once
  to pick vi/en, then `mlx_whisper.transcribe()` encodes the same audio again; `split_by_language`
  (`domain/segments.py`) adds detection calls on sub-turns, and each temperature fallback re-encodes. Measured
  fixed floor: ~1.4-1.6 s per call [local], so many short blocks cost far more than their audio.
- **Summarize (6 %).** Prefill + decode inside Ollama (Go + llama.cpp). Small share; not a target.
- **Hidden multiplier: swap.** whisper q4 peaks at 1.24 GB MLX [local], pyannote ~2.2 GB [local], qwen3:4b ~3 GB
  resident [est], next to a browser and a call on a 16 GB Mac with 16-20 GB swap already used. Every bench so far
  ran under "warn". Nobody knows yet whether 30 min is compute or page-in/page-out; it could be a large share.

Why not a rewrite: > 90 % of the time is inside compiled kernels (MLX Metal, PyTorch MPS, ffmpeg, llama.cpp);
Python only schedules them. A faster conductor does not make the orchestra play faster.

So the plan attacks, in order: **measure** (swap vs compute), **stop doing redundant work** (mic diarization,
double encoder), **use a faster diarization engine**, **keep models out of each other's way in RAM**, then move work
**into the meeting** (live A) and make install one click.

---

## 1. Goal and measurable targets

Goal: a 1 h meeting has notes within ~5-8 min of Stop on this Mac, without making the Mac or the call feel slow,
and a colleague installs the app without a terminal or a Hugging Face account.

| Metric | Baseline (source) | Target M1 (Python-only fixes) | Target M2 (+ faster diarizer) | Stretch (+ live A) |
|---|---|---|---|---|
| Post-Stop wall time, 1 h, 2 tracks | 1,792 s ≈ 30 min (EMA, extrapolated, under swap) | ≤ 900 s (50 %) | ≤ 480 s (≈ 8 min) | ≤ 300 s (≈ 5 min) |
| Diarize stage, 1 h | 899 s (EMA) | ≤ 500 s | ≤ 150 s | same |
| Transcribe stage, 1 h | 733 s (EMA) | ≤ 500 s | ≤ 500 s | ≤ 150 s (tail + re-decodes) |
| Peak memory of the worker (RSS + Metal) | whisper 1.24 GB MLX, pyannote ~2.2 GB, peak RSS 0.75-1.1 GB [local]; earlier 4 GB before cache cap | ≤ 2.5 GB; whisper, pyannote and the LLM never resident together | ≤ 2.0 GB | same |
| Swap growth during one 1 h job | unknown (4.9 M page-outs lifetime [local]) | measured, ≤ 1 GB | ≤ 500 MB | ≤ 500 MB |
| Quality guard: WER (vi, en, code-switch) | Phase 0 baseline | ≤ +0.5 pp | ≤ +0.5 pp | ≤ +0.5 pp vs offline (strict reuse) |
| Quality guard: DER (vi set) | Phase 0 baseline (community-1, torch) | ≤ +1 pp | ≤ +2 pp, speaker count right ≥ 80 % of files | same |
| Live A during a call | defers whenever pressure ≠ normal, i.e. almost always here | n/a | n/a | T2 pass: no audio glitch / FPS drop > 10 %, backlog median < 30 s, skipped < 5 % of speech |
| Install | 14 required steps, ~4.5 GB, 25-45 min, needs Xcode CLT + Homebrew + HF account (`one-click-install.md` section 1) | 10 steps (no HF) | - | 5-6 steps, no terminal, ~15 min wait on 100 Mbps, 1 Gatekeeper approval |

Why these numbers: 50 % is the bar the live-A study already used; 8 min is what a 5x diarizer plus the Python fixes
gives on paper (`realtime-feasibility.md` table: A + 5x diarizer = 19 % of today ≈ 345 s); quality guards reuse the
adoption thresholds of `speed-memory.md` section 5 so a speed win never silently costs accuracy.

---

## 2. Phase 0: measurement harness (do first)

**Why:** every 1 h number above is an extrapolation from sub-5-minute meetings measured under swap. Without a clean
baseline we cannot tell whether a change helped, or whether swap (not compute) is the real bottleneck. Measuring is
also the cheapest task with the biggest chance of changing the plan.

| Task | Files | Why |
|---|---|---|
| 0.1 `bench/pipeline_bench.py`: run `meeting-notes process` on a fixture copy in a fresh process (`nice 10`), record per-stage wall time (`status.json` timings), peak RSS (`/usr/bin/time -l`), MLX peak (`mx.get_peak_memory()`), MPS allocated, `vm_stat` page-ins/outs and `vm.swapusage` before/after, and `kern.memorystatus_vm_pressure_level` sampled every 1 s (reuse `adapters/outbound/load_probe.py`). One JSON line per run; median of 3. | `pipeline/bench/pipeline_bench.py` (new), reuse `bench/asr_bench.py` style | One command that answers "faster? more RAM? more swap?" for every later phase |
| 0.2 Fixtures: (a) synthetic long meetings 10 / 30 / 60 min, two tracks, stitched from the `asr_bench` `say` corpus (vi, en, code-switch, 2-6 speakers, some overlap, known text + RTTM); (b) ≥ 3 real consented meetings ≥ 10 min (vi-heavy, en, code-switched) **copied out by the user** into a gitignored fixture dir outside `~/MeetingNotes`, with hand-corrected transcript and speaker turns for 10 min excerpts. Never read or process recordings in `~/MeetingNotes` in place. | `pipeline/tests/e2e/make_synthetic.py` (extend: `--minutes`, `--speakers`), `bench/fixtures.md` (how-to, no data) | Synthetic gives exact truth and repeatability; real meetings give the numbers that matter (ambient noise, bleed, Vietnamese pacing). The live study showed short real clips decide nothing |
| 0.3 `bench/diar_bench.py` (`make | run <dir> <engine> | all`), each engine in its own process; DER (collar 0 and 0.25), JER, speaker-count error via `pyannote.metrics` | `pipeline/bench/diar_bench.py` (new) | Needed before any diarizer change; no diarization bench exists today |
| 0.4 Run condition labels: every result row stores pressure level at start, min/max during run, swap delta, Ollama models resident (`/api/ps`), AC/battery. Runs default to waiting for "normal" (timeout then `--allow-warn`, labelled). | inside 0.1 / 0.3 | Makes "under warn" vs "clean" comparable instead of mixed |
| 0.5 Baseline report: clean run (Ollama models stopped, pressure normal) vs typical run (warn) on the 60 min synthetic and the real set | results in a scratch dir; summary table appended to this plan | Splits the 30 min into compute vs swap; resets the targets with real numbers |

- **Expected gain:** none directly; decides priorities.
- **Risk:** low. Long synthetic TTS has no disfluencies, so real fixtures are mandatory for quality gates.
- **Acceptance:** 3 repeated runs within ±10 % wall time; report lists stage times, peak memory, swap delta for both conditions.
- **Effort:** 3 days (+ user time to pick and label real meetings).
- **User decision:** which meetings to donate as fixtures; nothing else.
- **Status (W1):** 0.1 + 0.2a + 0.4 built as `pipeline/bench/pipeline_bench.py` (`make | run | report`),
  `bench/meeting_fixture.py` (seeded `say` meetings, any length, 1-6 remote voices, optional second local voice
  and bleed, reference JSON + RTTM) and `bench/bench_metrics.py` (DER with optimal mapping and collar, WER per
  track, vm_stat / swap parsing). MPS allocation is not recorded (process RSS + MLX peak only). Open: 0.2b real
  fixtures, 0.3 `diar_bench`, 0.5 clean-vs-warn baseline (pressure was "warn" for every run so far).

---

## 3. Phases by impact / effort

### Phase 1: quick wins in Python (stop redundant work)

**Why this phase first:** both tasks remove work we do twice or do needlessly, in the two stages that are 91 % of
the time, with no new dependency and no install change. They also make every later measurement cheaper.

#### 1.1 Skip full pyannote on the mic track when it holds one voice

- **Why:** the mic is almost always just you; `domain/speakers.py:resolve_two_tracks` already labels it "Me" when
  `mic_speakers = "me"` or one real cluster is found, yet `diarize_tracks.py` pays for a full pyannote pass first.
  Pyannote cost scales with track length, so the mic pass is roughly half the stage. Cheaper alternative to answer
  "one voice or several": VAD for speech regions + a handful of speaker embeddings (the ungated wespeaker
  `embedder()` already exists in `pyannote_diarizer.py`) and a cosine-spread check. Better than always skipping,
  because in-person meetings (several voices on the mic) still get the full path.
- **Tasks:** `application/diarize_tracks.py` (fast path before `diarizer.diarize(tracks["mic"])`);
  `application/ports.py` (`Diarizer.voice_check(audio) -> (turns, single: bool)`);
  `adapters/outbound/pyannote_diarizer.py` (VAD turns + K embeddings over the longest voiced spans);
  `domain/speakers.py` or `domain/clustering.py` (pure single-voice decision, thresholds as constants);
  `mic_speakers = "me"` skips the check entirely. Diarization note says which path ran.
- **Expected gain:** up to ~400-450 s of 899 s for a 1 h meeting [est]; ≈ 25 % of total.
- **Risk:** low-medium. In-person meeting misclassified as one voice merges people into "Me". Mitigation: bias the
  threshold toward "several voices" (falls back to full pyannote), and bleed handling stays unchanged.
- **Acceptance:** on fixtures, mic labels identical to today on single-voice mics; ≥ 95 % of multi-voice mic fixtures
  take the full path; DER unchanged ±0.5 pp; diarize stage ≥ 35 % faster on the 60 min synthetic.
- **Effort:** 2 days. **Decision:** none (default behaviour keeps today's results).
- **Status (W1): built**, config key `mic_voice_check = true` (new public key). `domain/voice_check.py`: energy VAD,
  up to 48 evenly spread 3 s windows with remote speech (dilated system turns) excluded, wespeaker embeddings,
  average-linkage split at cosine distance 0.45; sure single voice only if one group holds all but <= 10 % stray
  windows; < 30 s of mic speech is single by construction. Several voices or unsure: full pyannote, byte-identical
  output (unit-tested). Check costs ~1-2 s (+ ~4 s embedding model load). Measured: section 7.

#### 1.2 One encoder pass per block (dedupe language detection)

- **Why:** each block is encoded 2+ times (detect, then transcribe; more with `split_by_language` and temperature
  fallback). The encoder is the expensive half of a short-block call; the ~1.5 s per-call floor [local] is mostly
  this. Whisper's decoder accepts precomputed audio features (`mlx_whisper.decoding` skips the encoder when given
  `(n_audio_ctx, n_audio_state)` features), so we can encode once, detect language from those features and decode
  from them. Batching blocks (WhisperX style) is the bigger but riskier version; do the dedupe first.
- **Tasks:** `adapters/outbound/mlx_transcriber.py` (`encode(audio)` → features; `detect_language(features)`;
  `transcribe(features_or_audio, language)` through `mlx_whisper.decoding.decode` with our own fallback loop,
  segment timestamps as today); `application/ports.py` (Transcriber protocol: optional `transcribe_auto(audio,
  allowed, prior)`); `application/transcribe_blocks.py:decode_block` and the `detect` closure for
  `split_by_language` (cache features per span). Pin the `mlx-whisper` version in `uv.lock` and test against it.
- **Expected gain:** 30-40 % of transcribe on short blocks [est] → ~200-280 s of 733 s; less on long blocks.
- **Risk:** medium: we take over part of mlx-whisper's call path (seek loop, fallback, timestamps). Mitigation: only
  for blocks ≤ 30 s (all blocks are ≤ 28 s via `whisper_max_chunk_sec`), keep the old path behind a flag for A/B.
- **Acceptance:** `asr_bench` text identical (or WER within ±0.2 pp) at temperature 0 on all variants; language
  choice identical; transcribe stage ≥ 25 % faster on the 60 min synthetic; live chunk p50 decode < 1.2 s.
- **Effort:** 2-3 days. **Decision:** none.
- **Status (W2): built.** `Transcriber.transcribe_auto(audio, choose)` (new port method) encodes the first 30 s
  window exactly as `mlx_whisper.transcribe` builds it, detects the language on those features, and decodes through
  mlx-whisper's own `transcribe` with an `_EncodeOnce` model proxy that serves the precomputed features (checked
  equal to the window) and encodes every other window once, so temperature fallbacks no longer re-encode either.
  We did not fork the seek/fallback loop, so the old path needs no flag: decoding is identical by construction.
  Blocks with several VAD spans still detect on all voiced audio (one extra pass); `split_by_language` sub-turn
  detection is unchanged. Real-model A/B on 40 fixture blocks: language 40/40 and text 40/40 identical, decode
  time -45 %. Measured: section 7.

#### 1.3 Small items (only if Phase 0 shows they matter)

| Item | Why | Files | Gain | Effort |
|---|---|---|---|---|
| Encode the m4a listening copies after notes are written (or in a background step) | They are not needed for diarize/transcribe/summary; the user waits for them today | `application/process_meeting.py:stage_prepare`, `stage_finalize` | part of 54 s [est] | 0.5 day |
| Overlap model load with `prepare` | Loading whisper/pyannote and Metal compile take 5-15 s while ffmpeg runs alone | `process_meeting.py`, `adapters/outbound/model_cache.py` | 5-15 s | 0.5 day |
| Raise `diarization_batch_size` to 16-32 only when on AC and the app is idle (no recording) | Small batches were chosen for short GPU bursts during calls; after Stop nobody is on a call | `config/settings.py`, `pyannote_diarizer.py` | small [gap] | 0.5 day |

### Phase 2: memory and swap

**Why:** if Phase 0 shows significant page-outs during the job, removing them may beat any engine change, and it
is a prerequisite for live A and live polish, which add models while a call is running. The rule is simple: one
heavy model resident at a time, and give memory back immediately.

| Task | Why | Files | Gain | Effort |
|---|---|---|---|---|
| 2.1 Memory telemetry in the job: peak RSS, MLX peak, swap delta and pressure transitions per stage, additive keys in `status.json` timings and `pipeline.log` | Lets every real meeting (not just benches) show whether swap hurt it | `adapters/outbound/progress_reporter.py`, `load_probe.py`, `process_meeting.py` | diagnostic | 1 day |
| 2.2 Strict sequencing: before diarize/transcribe, if an Ollama model is resident (`/api/ps`) and pressure ≥ warn, send `keep_alive: 0` for **our** summary model only; keep `ollama_preload` off by default; release pyannote (`torch.mps.empty_cache`, `gc`) before whisper loads (already done by `done_with_diarizer`, verify with 2.1) | qwen3:4b (~3 GB) kept alive by a previous job or a manual chat competes with whisper/pyannote on a 16 GB Mac | `adapters/outbound/ollama_client.py`, `process_meeting.py`, `model_cache.py` | unknown, possibly large [est] | 1 day |
| 2.3 Cap torch MPS: `PYTORCH_MPS_HIGH_WATERMARK_RATIO` for the worker, and re-check `mlx_cache_limit_mb = 256` on 1 h fixtures | MPS caches freed buffers like MLX did (MLX cache growth cost ~2.5 GB on 1 h before the cap) | `adapters/outbound/system_resources.py`, `pyannote_diarizer.py` | ~0.5-1 GB peak [est] | 0.5 day |
| 2.4 Summary memory: measure KV cache at `ollama_num_ctx = 12288` on a 1 h vi transcript; compare with chunked extraction at a smaller ctx (`summary_chunk_chars`) | The LLM is the largest resident model; a 12k ctx adds KV memory at the end of the pipeline, when swap is already high | `config/settings.py`, `application/summarize_meeting.py`, `bench/summary_bench.py` | 0.3-1 GB [est] | 1 day |
| 2.5 Smaller models only where quality holds: whisper is already turbo q4; test `qwen3:4b-instruct-2507` / `gemma3:4b` for summary quality per GB; no smaller whisper (vi WER risk) | Shrinks the biggest resident model without touching ASR quality | `bench/summary_bench.py` | per model | 1 day bench |

- **Risk:** low; all changes are unloads, caps and measurements. Unloading Ollama costs a reload (~2-3 s) at summarize.
- **Acceptance:** on the 60 min fixture under "typical" conditions, swap growth ≤ 1 GB and no new "critical"
  transitions; worker peak ≤ 2.5 GB; wall time not worse.
- **Effort:** 3-4 days. **Decision:** none (all within current config semantics; new config keys avoided).

### Phase 3: faster diarization engine

**Why:** even after 1.1, diarization stays the largest stage, and with live A it is the only big thing left after
Stop (A alone saves at most 41 %). The speed comes from the engine (Core ML on the Neural Engine, or ONNX on CPU),
not the host language, and the ANE path also takes diarization off the GPU that whisper and the call use.

| Task | Why | Files | Expected gain | Effort |
|---|---|---|---|---|
| 3.1 Load community-1 from a bundled local dir (sha256-pinned, CC-BY attribution), HF token optional | Same weights for every engine comparison and for install (removes the HF gate, Phase 7 M1). Zero quality change | `config/settings.py` (local path accepted in `diarization_models`), `pyannote_diarizer.py`, `adapters/outbound/hf_hub.py`, `scripts/` fetch-and-verify | none (enabler) | 0.5-1 day |
| 3.2 Vietnamese DER set: 2-3 consented real vi/code-switched meetings with hand-corrected speaker turns (from 0.2) + synthetic stitched set + 3-5 AMI/VoxConverse files for sanity | No engine has published Vietnamese DER; vendor numbers are English/Mandarin. Language-dependent behaviour exists even for acoustic models (soniqo head-to-head) | `bench/diar_bench.py` | gate | 2 days (+ labeling) |
| 3.3 sherpa-onnx adapter (pyannote segmentation-3.0 ONNX + 3D-Speaker/WeSpeaker embeddings), opt-in | Python wheel, no torch, Apache-2.0, ungated; easiest second engine; better than today's agglomerative fallback | `adapters/outbound/sherpa_diarizer.py` (new), `entrypoints/wiring.py`, config `diarization_engine` | 2-5x [est, no Mac numbers] | 2-4 days |
| 3.4 FluidAudio helper CLI (Swift, Core ML port of community-1 on ANE) returning turns as JSON; Python adapter shells out | Highest claimed speed (65-122x RT on ANE [V], 129 MB models), same model family as today, off the GPU | small Swift target in `app/` built into the bundle, `adapters/outbound/fluidaudio_diarizer.py` (subprocess, JSON), `wiring.py` | 5-20x [V, unverified on vi/M1] | 3-5 days |
| 3.5 Decision run: community-1 torch vs sherpa vs FluidAudio on 3.2, while whisper is loaded; wall time, peak memory, DER, speaker count | One table decides default vs opt-in | `bench/diar_bench.py` | - | 1 day |

- **Order inside the phase:** 3.1 → 3.2 → 3.3 → 3.4 → 3.5. sherpa first because it is pure Python and cheap; FluidAudio
  second because it has the biggest upside but adds a Swift binary.
- **Risk:** medium. DER regressions on similar voices and on Vietnamese; sherpa has no PLDA/VBx (weaker speaker
  counting); FluidAudio reported 13.9-15.1 VoxConverse vs ~11 for torch [V]. A new public config key.
- **Acceptance (adopt as default):** DER within +2 pp of community-1 torch on the vi set, speaker count correct
  ≥ 80 % of files, ≥ 5x faster on the 60 min fixture, no rise in peak memory. Otherwise keep it opt-in, or as the
  ungated fallback tier replacing agglomerative clustering.
- **Effort:** 9-13 days. **Decisions:** new config key `diarization_engine` (public API); bundling the FluidAudio
  binary and models; whether a passing engine becomes the default.

### Phase 4: warm worker

**Why:** the worker unloads models after each stage (`keep_models_warm = False`) and exits after
`worker_idle_release_min = 1`, which is right for RAM but pays import + load + Metal compile (5-15 s, more under
swap) on every job and every queued import. Keeping models warm only while memory allows gets the latency without
the RAM cost. AGENTS rule 9 still holds: never spawned at launch or while recording unless live is on.

- **Tasks:** adaptive keep-warm in `adapters/outbound/model_cache.py` (keep while the job queue is non-empty and
  pressure is normal; release on warn); app sends `warmup` when Stop is pressed so load overlaps `prepare`
  (`app/Sources/MeetingNotes/Pipeline/` worker client, existing `warmup` command); live job hands its loaded whisper
  to the Stop-time job (already designed, verify with 2.1).
- **Expected gain:** 5-15 s per meeting [est]; more for batch imports. **Risk:** low (RAM held slightly longer).
- **Acceptance:** second job in a queue starts transcribing ≥ 5 s earlier; no model held under "warn".
- **Effort:** 1-1.5 days. **Decision:** none (default unchanged when pressure is not normal).

### Phase 5: live transcription (design A) memory-warn policy

**Why:** design A is built (opt-in) but `domain/live_backlog.py:decide()` defers whenever pressure is above
"normal". On this Mac pressure is "warn" most of the time, so live almost never runs and Stop saves nothing. "Warn"
alone does not mean decoding will hurt: whisper q4 is already resident in the live job (1.24 GB), and one chunk at
`nice 10` adds little new memory. The right signal is *swap growing now*, not the pressure level. Without T2 (load
during a real call) we do not know if live disturbs the call, so T2 gates this phase.

| Task | Why | Files | Effort |
|---|---|---|---|
| 5.1 T2: 30 min Zoom/Meet with camera, `meeting-notes live --simulate 1x` vs idle; `powermetrics`, pressure, swap, Zoom stats, `TrackWriter.droppedBuffers` | The only untested risk of A: call stutter from GPU contention | bench script + manual run | 1 day |
| 5.2 T3/T4 re-run on the ≥ 10 min real fixtures (strict reuse rule) | Shipped A was validated on 8.9 min of real audio in total | `bench/live_chunk_bench.py`, `live_reuse_bench.py` | 0.5 day |
| 5.3 Policy "balanced": decode under "warn" when the model is already resident, swap grew < X MB over the last 2 min and backlog < max; defer otherwise; on "critical" skip and release whisper. "strict" = today's behaviour | Lets live run on a normally loaded 16 GB Mac while still backing off when it actually starts to thrash | `domain/live_backlog.py` (`LoadSample.swap_rate_mb_min`, `model_resident`), `adapters/outbound/load_probe.py` (`vm.swapusage`), `application/live_transcribe.py`, `config/settings.py`; Swift: status reason text in `LiveEvents.swift`, `L10n.swift` | 2-3 days |

- **Expected gain:** post-Stop time 59-72 % of today with today's diarizer; 19-47 % with a 2-5x diarizer
  (`realtime-feasibility.md` table) [local replay + est].
- **Risk:** high-medium: call quality, memory. Mitigation: opt-in stays default off; T2 must pass before "balanced"
  is offered.
- **Acceptance:** T2 pass criteria (`realtime.md` section 5) under "balanced"; live decodes ≥ 80 % of speech
  during a typical (warn) meeting; final transcript within 0.5 pp WER of offline on real fixtures.
- **Effort:** 3.5-4.5 days. **Decision:** run live under memory "warn" at all, and which default (strict vs balanced);
  new config key `live_memory_policy`.

### Phase 6: live polish

**Why:** whisper already punctuates; most ugliness in live text is chunk-boundary artefacts (split sentences,
lowercase fragment starts, missing final period), fillers and glossary casing. Deterministic rules fix those in
< 10 ms with zero RAM and zero meaning risk; an LLM adds 1.2-2 GB next to a call on a Mac already at "warn", and
small models over-correct Vietnamese tones. So: rules first, LLM only opt-in and only when the Mac has room.
Polish is a display layer; it never feeds `transcript.json`, notes or the summary.

#### 6.1 Tier 1: rules (default when polish is on)

- **Tasks:** `domain/live_polish.py` (pure: NFC, spacing, join lowercase continuation onto an unterminated
  same-track segment, sentence-start casing, final period at paragraph close, glossary casing, `collapse_repeats`,
  optional pure-interjection hiding, rule-based paragraphing); call site in `application/live_transcribe.py` (or
  sibling `live_polish.py` to stay ≤ 300 lines); additive contract: `ready.features += "live_polish"`, `live` gains
  `"polish":"off|rules|llm"`, new `live_polish` event; Swift `WorkerEvent.livePolish`, `LiveTranscript` polish map,
  pill "raw" toggle, Settings › Recording toggle, `L10n.swift`; both sides in one commit with tests (rule 5).
  `bench/live_polish_bench.py`: rules vs raw on synthetic + ~30 hand-written vi/en spontaneous paragraphs.
- **Expected gain:** readability; boundary F1 ≥ raw + 0.10 [target]. **Risk:** near zero.
- **Acceptance:** WER vs reference unchanged (strict: ±0.0-0.2 pp), casing accuracy ≥ 0.95, each paragraph replaced
  at most twice in the pill.
- **Effort:** 3-4 days. **Decision:** none beyond the opt-in UI.
- **Status (2026-10-23): Python side built**, off by default behind config key `live_polish = "off" | "rules"`
  (+ `live_polish_pause_sec` 2.5, `live_polish_max_words` 80; new public keys). `domain/live_polish.py` (rules +
  `LivePolisher` paragraphing, emits only changed paragraphs), call site in `application/live_transcribe.py`
  (`_announce`, paragraphs closed at stop), `ProgressReporter.live_polish`, worker `ready.features` += `"live_polish"`,
  `live` cmd `"polish"` overrides config for the job, event
  `{"event":"live_polish","job","track","speaker","para","seqs","tier":"rules","text"}`. Raw partials and
  `live_segment` unchanged; no `.work/transcript.polish.jsonl` (polish is recomputed from the re-announced partials on
  resume). Conservative choices: `ừ` (yes) and sentence-final `à` kept; no "?" for vi question particles; old/new tone
  placement (`hoà`/`hòa`) left as decoded. Unit tests incl. Vietnamese NFD input, tone placement, reduplication.
  **Not done:** Swift side (`WorkerEvent.livePolish`, `LiveTranscript` polish map, pill raw toggle, Settings toggle,
  `L10n`), `bench/live_polish_bench.py` (WER/boundary F1/casing acceptance not measured yet).

#### 6.2 Tier 2: LLM strict (opt-in, later)

- **Why later:** worth it only if it actually runs. Run the probe (`gemma3:1b`, `qwen3:1.7b`, 3 paragraphs, normal
  pressure) and the T2 skip-rate measurement first; if the gate skips Tier 2 most of the time, do not ship it.
- **Tasks:** `adapters/outbound/ollama_client.py` (plain-text method, `keep_alive` "2m", unload on pressure);
  deterministic guard in `domain/live_polish.py` (no inserted/substituted words, diacritics kept, digits/glossary/
  language spans unchanged, length ratio 0.8-1.1); scheduling in the live loop only when the chunk queue is empty,
  pressure normal and on AC; config keys `live_polish_model` (default `qwen3:1.7b`), `live_polish_pause_sec`,
  `live_polish_max_words`.
- **Expected gain:** sentence/paragraph quality beyond rules; latency +3-4 s per paragraph [est].
- **Risk:** RAM (+1.2-2 GB), meaning drift in vi. **Acceptance:** guard rejection < 10 %, 0 hallucinations after
  guard, human "same meaning" ≥ 97 %, p50 ≤ 5 s, no normal→warn transition caused by polish.
- **Effort:** 4-6 days incl. bench. **Decision:** whether to offer an LLM during recordings at all; default model.

### Phase 7: one-click install (GitHub Releases, self-signed, first-run wizard)

**Why:** a colleague today needs 14 steps, Xcode CLT, Homebrew, a terminal and a Hugging Face account. The HF step
exists only because pyannote's gate is a lead-capture form; the licence (CC-BY-4.0) allows bundling. Without an
Apple Developer account one Gatekeeper "Open Anyway" is unavoidable, so the design makes it the *only* manual
security step: the app downloads everything else itself (app-initiated downloads are not quarantined) and signs
every release with one stable self-signed certificate so mic/screen permissions survive updates. A frozen Python
bundle (PyInstaller) or a Swift-native rewrite would be 2-8 weeks for no signing benefit.

| Milestone | Tasks (files) | Why | Effort |
|---|---|---|---|
| M1 No HF token | = task 3.1; NOTICE + Settings › About attribution; `HF_TOKEN` stays an optional override | Removes steps 9-12 (account, gate form, token, `.env`) at zero quality cost | 0.5-1 day |
| M2 Packaged mode | Detect pipeline inside the bundle; `MNPipelineDir` → bundle, config + `.env` → `~/Library/Application Support/MeetingNotes/`; bundle `uv`; `UV_PYTHON_PREFERENCE=only-managed`, `UV_PROJECT_ENVIRONMENT` in Application Support (`app/Sources/MeetingNotes/Pipeline/`, `config/loader.py`, `config/__init__.py:hf_token`). Dev mode (repo + `install.sh` + `build-app.sh`) unchanged; `pipeline/`, `models/`, `.env` not moved (rule 7) | The app today bakes the repo path, so every user must build from source | 2-3 days |
| M3 First-run wizard | Swift wizard: "Set up (≈ 3.4 GB)" → `uv sync --frozen`, `meeting-notes setup --json` (whisper; existing progress event shape), Ollama detect / install + `qwen3:4b` pull, permission checklist; resumable, progress, ETA, Retry; recording works before setup finishes (`app/Sources/MeetingNotesUI/Settings/` or new `Setup/`, `adapters/inbound/commands.py`) | One button instead of 8 terminal steps; separate process keeps the worker protocol frozen | 2-3 days |
| M4 ffmpeg optional | `afconvert`/AVFoundation for m4a and common imports; ffmpeg only for webm/mkv (`adapters/outbound/ffmpeg_audio.py`, `audio_files.py`) | Removes Homebrew and GPL bundling questions | 0.5-1 day |
| M5 Release script | `scripts/release.sh`: build, sign with the stable self-signed identity (`setup-signing.sh`), `hdiutil` dmg with an Applications alias and a 3-step "Open Anyway" picture, `gh release create` locally (no macOS CI minutes) | Repeatable releases; stable designated requirement keeps TCC grants | 0.5-1 day |
| M6 In-app updater (public releases only) | Poll the public Releases API, download, swap bundle | No re-approval after the first; impossible without a token if releases are private | 1 day |
| M7 Fresh-Mac acceptance | New macOS user account (or a colleague): dmg → Applications → Open Anyway → Set up → 2 permissions; then update once | Proves the target | 0.5 day |

- **Expected gain:** 14 → 5-6 steps, no terminal, no HF account, ~15 min wait on 100 Mbps; dmg ~0.1-0.15 GB,
  first-run download ~3.4 GB.
- **Risk:** medium: runtime downloads from PyPI/GitHub extend AGENTS rule 1; private repo blocks auto-update;
  losing the signing key forces everyone to re-grant permissions once.
- **Acceptance:** M7 passes with ≤ 6 user steps and 1 Gatekeeper approval; permissions survive an update;
  `doctor` green; a 2 min test meeting produces notes.
- **Effort:** 7-10.5 days. **Decisions:** release visibility, bundling weights, Ollama strategy, network scope,
  signing-key holder, bundle id (section 5).

---

## 4. Order and dependencies

```
Phase 0 (harness, baseline) ─┬─> 1.1 mic skip ─┐
                             ├─> 1.2 encoder ──┼─> checkpoint A (≤ 50 %?)
                             ├─> 2 memory/swap ┘
                             └─> 3.1 bundled weights ─> 3.2 vi DER set ─> 3.3 sherpa ─> 3.4 FluidAudio ─> 3.5 decide ─> checkpoint B (≤ 8 min?)
3.1 = M1 ─> M2 ─> M3 ─> M4 ─> M5 ─> (M6 if public) ─> M7
2 (telemetry) ─> 5.1 T2 ─> 5.3 live policy ─> 6.1 rules polish ─> 6.2 LLM polish (only if probe + skip rate allow)
4 warm worker: after 2.1 (needs memory signal)
```

Week by week (one developer, ~5 working days per week; effort from section 3):

| Week | Work | Exit check |
|---|---|---|
| W1 | Phase 0 harness + fixtures + baseline (3 d); 1.1 mic-track skip (2 d) | Baseline table (clean vs warn); mic skip passes on fixtures |
| W2 | 1.2 single encoder pass (3 d); 2.1-2.3 telemetry, sequencing, MPS cap (2 d) | **Checkpoint A:** post-Stop ≤ 50 % on 60 min fixture, swap measured |
| W3 | 3.1 / M1 bundled community-1 (1 d); 3.2 vi DER set (2 d); 1.3 small items + 2.4-2.5 if Phase 0 flagged them (2 d) | HF token no longer needed; DER baseline |
| W4 | 3.3 sherpa-onnx (3 d); 3.4 FluidAudio CLI start (2 d) | sherpa DER/speed row |
| W5 | 3.4 finish (2 d); 3.5 decision run (1 d); Phase 4 warm worker (1.5 d) | **Checkpoint B:** engine decision; post-Stop ≤ 8 min if an engine passes |
| W6 | 5.1 T2 + 5.2 real T3/T4 (1.5 d); 5.3 live memory policy (3 d) | T2 verdict; live runs under "balanced" |
| W7 | 6.1 Tier 1 rules polish + bench (4 d); buffer (1 d) | Rules polish shipped behind opt-in |
| W8 | M2 packaged mode (3 d); M3 wizard start (2 d) | App runs from the bundle |
| W9 | M3 finish (1 d); M4 ffmpeg optional (1 d); M5 release script (1 d); M7 fresh-Mac test (1 d); M6 if public (1 d) | First GitHub Release installs in ≤ 6 steps |
| W10 (optional) | 6.2 Tier 2 probe (0.5 d), then build only if probe + T2 skip rate allow (4-6 d) | Go / no-go on LLM polish |

Install (W8-W9) can move earlier if colleague onboarding is more urgent than speed; it depends only on M1 (W3)
and the decisions in section 5.

---

## 5. Open decisions for the user

| # | Decision | Options | Blocks | Recommendation |
|---|---|---|---|---|
| 1 | **Code repo visibility**: GitHub API reports `hoangphu7122002/meeting-notes` as **public**, while the stated rule is "private" | make private now / keep public | everything public-facing (weights, binaries) | Decide now; if private is the rule, flip it before any release |
| 2 | **Live under memory "warn"** | strict (today: never decodes under warn) / balanced (swap-rate gate) / off | Phase 5 | Balanced as opt-in, only after T2 passes |
| 3 | **Release repo visibility** | private repo + collaborator invites (manual updates, no updater) / separate public `meeting-notes-releases` repo (link install, auto-update) | M6, M3 download sources | Public releases repo, private code |
| 4 | **Bundle pyannote community-1 weights** | bundle in app (CC-BY-4.0, attribution) / third-party `pyannote-community` mirror (same sha256) / keep HF gate | M1, 3.1 | Bundle, sha-pinned, NOTICE in app |
| 5 | **Ollama** | download official Ollama.app on demand / bundle headless `ollama` (+181 MB) | M3 | Official on demand; reuse an existing install |
| 6 | **Bundle id** | keep `com.hoangphu.meetingnotes` / company id before first release (changing later resets permissions) | M5 | Decide before the first public release |
| 7 | New public config keys | `diarization_engine`, `live_memory_policy`, `live_polish_*` (rule 6: public API once shipped) | Phases 3, 5, 6 | Approve names before merge |
| 8 | Runtime network scope | allow PyPI + GitHub at first run (extends rule 1) / ship Python + wheels in a ~0.5 GB dmg | M2-M3 | Allow, pinned by `uv.lock` hashes |
| 9 | Signing key holder | one release Mac / CI secret | M5 | One Mac + encrypted backup |
| 10 | ffmpeg | drop (AVFoundation) / bundle LGPL build | M4 | Drop; webm/mkv imports need user-installed ffmpeg |
| 11 | Default diarizer after 3.5 | keep community-1 torch / switch to the passing engine | Checkpoint B | Switch only if acceptance passes on the vi set |
| 12 | Fixture donation | which ≥ 10 min real meetings may be copied out and hand-labelled | Phase 0, 3.2, 5.2 | 3 meetings: vi-heavy, en, code-switched |

---

## 6. Out of scope / rejected

| Item | Reason |
|---|---|
| Go or Rust rewrite of the pipeline | > 90 % of time in native kernels; gain ~1-5 % for 4-8 weeks plus quality risk (`native-backend.md`) |
| Swift-native rewrite (option D: WhisperKit/whisper.cpp + FluidAudio, no Python) | Deferred, not rejected: a packaging win (−1.4 GB env), not speed; breaks the frozen contract; revisit only if install size becomes the main goal |
| Design C: MLX streaming Whisper (WhisperLiveKit / SimulStreaming) | Continuous GPU load during calls, draft text only, no vi/code-switch evidence (`realtime.md` section 3) |
| Design B: WhisperKit live captions | Only if captions are still wanted after A ships and T1 passes |
| DiariZen | Best open DER, but weights CC-BY-NC-4.0 and a CUDA-pinned stack |
| NVIDIA Sortformer 4spk / Nemotron-3 | 4-speaker cap / NVIDIA-only NeMo runtime |
| Rev reverb-diarization, Picovoice Falcon | Gated and non-commercial / proprietary |
| Parakeet ASR | No Vietnamese |
| whisper.cpp instead of mlx-whisper | Equal or slower on Mac [B]; same kernels class |
| PhoWhisper switch | A quality track, not speed; separate study (`phowhisper-mlx.md`) |
| Live polish with qwen3:4b during recording, token-level streaming correction, MLX-LM inside the worker | RAM (≈ 3 GB) next to a call; flicker; second LLM runtime against rule 2 |
| Whisper style-prompt as "polish" | Changes the authoritative transcript; separate ASR experiment |
| Frozen Python bundle (PyInstaller), Homebrew cask, `curl \| sh` installer | 2-3 weeks and ~1.5 GB per update without signing benefit; cask brings back Homebrew + quarantine; not one click |
| Notarization / Developer ID | No Apple Developer account (user decision) |
| Apple SpeechAnalyzer | macOS 26 only |
| Cloud ASR, diarization or LLM | AGENTS rules 1-2 |

---

## 7. Measurements (W1)

All runs: M1 Pro 16 GB, on battery, Ollama models not resident, summaries skipped, pipeline priority "low", one
job at a time. **Every run below ended under memory pressure "warn"** (started "normal" except the 2 min smoke;
swap used ~17-19 GB), so these are "typical", not "clean", numbers. Synthetic `say` fixtures only.

Mic voice check verdicts (no pipeline run): 2 min and 12 min single voice → one voice (17/17, 48/48 windows);
10 min with a second person on the mic → several voices (full path); 10 min with speaker bleed → one voice
(47/48 windows, bleed excluded).

`pipeline_bench.py run <12 min, 1 local voice, 2 remote> --set mic_voice_check=true|false`, 2 runs each (medians):

| | diarize | transcribe | wall | peak RSS | WER all (mic) | DER (collar 0 / 0.25) | mic labels |
|---|---|---|---|---|---|---|---|
| check off (today) | 104.9 s | 171.5 s | 288.1 s | 1.34 GB | 6.88 % (12.55 %) | 5.3 % / 0.5 % | Me |
| check on | 60.6 s (**-42 %**) | 187.7 s | 260.0 s (**-10 %**) | 1.41 GB | 7.49 % (13.72 %) | 4.4 % / 0.3 % | Me |

2 min smoke (1 run each, warn): diarize 26.9 → 21.5 s, WER identical, DER 4.6 → 4.1 %.

- Acceptance "diarize ≥ 35 % faster" passes on the 12 min fixture (60 min not run: pressure).
- WER is deterministic across repeats. The +0.61 pp is one whisper hallucination: a 0.37 s segment at the end of
  a VAD-bounded block decoded as 20 words of YouTube outro ("Cảm ơn các bạn đã theo dõi ... lalaschool"); the
  phrase filter (`domain/segments.py:is_hallucination`) misses it because the block is long and the text is longer
  than the phrase + 20 chars. Excluding that sentence on both sides, the skip path has fewer mic errors than today (167 vs 175 of
  1,028 words). Follow-up: reject segments whose word rate is impossible (> ~8 words/s) when they contain a known
  phrase; re-measure before calling the WER guard met. **Done in W2 (section 8): guard met.**
- Transcribe +16 s: VAD gives more, shorter mic turns (75 vs 56) than pyannote, so more whisper calls; 1.2 (one
  encoder pass) attacks exactly this per-call floor.

## 8. Measurements (W2: hallucination filter + 1.2 single encoder pass)

Same machine and fixture (12 min, 1 local voice, 2 remote, `mic_voice_check` on = default), on battery (57 % ->
34 %), pressure "warn" at every run (some started "normal"), swap ~17-19 GB, Ollama models not resident, summaries
skipped, nice 10 + utility QoS, one job at a time. "before" = e372e15 (W1 head), "after" = c757776 (both changes),
`--repeat 2` each, medians (repeats within 1 %):

| | diarize | transcribe | wall | peak RSS | MLX peak | WER all (mic / system) | DER (c0 / c0.25) |
|---|---|---|---|---|---|---|---|
| before | 58.4 s | 186.4 s | 256.1 s | 1.51 GB | 1.25 GB | 7.49 % (13.72 % / 0.54 %) | 4.45 % / 0.33 % |
| after | 59.3 s | 133.2 s (**-29 %**) | 203.9 s (**-20 %**) | 1.52 GB | 1.25 GB | 6.41 % (11.67 % / 0.54 %) | 4.45 % / 0.33 % |

- Transcript diff before -> after: exactly one segment removed, the 0.37 s / 21-word outro ("Cảm ơn các bạn đã theo
  dõi và ủng hộ cho kênh lalaschool Để không bỏ lỡ những video hấp dẫn"); every other segment's text, timing and
  language is identical (encoder reuse changes no output). With it gone the mic-skip path beats W1's full path on
  WER (6.41 % vs 6.88 % all, 11.67 % vs 12.55 % mic), so the 1.1 WER guard is met.
- Filter (`domain/hallucination.py`): known vi/en phrases match ignoring case, punctuation and spaces
  ("lalaschool", "amara.org" never matched before); a segment with a phrase is dropped when it is little more than
  the phrase, the block is < 8 s, phrases cover >= 50 % of its letters, or its words exceed 8 per second of
  whisper's raw segment time; long one-word loops are dropped; without a phrase only > 15 words/s in < 1 s from an
  unsure window (avg logprob < -0.8 or no-speech > 0.5). Unit tests hold real speech that contains the phrases.
- 1.2 acceptance: text identical (pass), language identical (pass), transcribe >= 25 % faster (pass, -29 % on
  12 min; 60 min not run: battery). Live chunk p50 not re-measured.
- Diarize did not change (no code change there). A first "before" pair run from a bare git worktree fell back to
  clustering (no `.env`/`models` there; diarize 12 s, DER 4.1 %) and was discarded (`w2-before-nopyannote-invalid`
  in results.jsonl).
