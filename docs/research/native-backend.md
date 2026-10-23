# Native backend (Go / Rust / Swift) vs Python: would it be faster?

Date: 2026-10-23. Status: research only (no code changed). Machine: M1 Pro, 16 GB, macOS 15.5.
Question: would rewriting the pipeline (`pipeline/`, Python) in Go or Rust make processing faster?
Inputs: [`speed-memory.md`](speed-memory.md), [`phowhisper-mlx.md`](phowhisper-mlx.md),
[`realtime-feasibility.md`](realtime-feasibility.md), [`one-click-install.md`](one-click-install.md), the code, and a few
light local measurements. Labels as in the other docs: **[local]** measured here, **[V]** vendor claim, **[B]** blog or
single run, **[est]** estimate from code reading. No model profile was run: `kern.memorystatus_vm_pressure_level`
was 2 (warn) during this study, so heavy runs were skipped (the learning spike in section 7 covers them).

## 1. Verdict

**No meaningful speed gain from rewriting the glue in Go or Rust: roughly 1-5 % of post-Stop time at best.**
More than 90 % of the time is spent inside compiled engines that Python only calls: MLX Metal kernels (whisper),
PyTorch MPS kernels (pyannote), ffmpeg (C) and Ollama (Go + llama.cpp). Rewriting the caller does not make those
kernels faster.

The real speed levers are **which engine and which algorithm**, and most of them are reachable from Python:

| Lever | Stage | Expected effect | Needs Go/Rust? |
|---|---|---|---|
| Faster diarization engine (Core ML/ANE or ONNX port of pyannote) | diarize (50 %) | 2-20x faster stage [V, unverified on vi] | No (Python bindings exist) or a small native helper CLI |
| Skip full pyannote on the mic track when it holds one voice | diarize | up to ~half the stage [est] | No |
| One encoder pass per block (language detection reuses it) | transcribe (41 %) | up to ~30-40 % of the stage on short blocks [est] | No |
| Measure and remove swap (memory pressure was "warn" in every bench) | all | unknown multiplier, possibly large | No |
| Native rewrite of glue code | all | ~1-5 % [est] | Yes |

Where a native backend **does** pay off: install size (no 1.4 GB Python env), startup of a few seconds, lower
baseline RAM, one runtime instead of two. Those are packaging wins (see [`one-click-install.md`](one-click-install.md)
option D), not speed wins. If that path is taken, **Swift-native** fits this app better than Go or Rust.

## 2. Mental model: Python is the conductor, not the orchestra

A pipeline like ours has two kinds of code:

- **Kernels**: the math (matrix multiplies, convolutions, attention). Written in C++/Metal/Objective-C, run on the
  GPU, the Neural Engine (ANE) or vectorized CPU. Here: MLX (whisper), PyTorch MPS (pyannote), numpy/scipy (BLAS),
  ffmpeg, llama.cpp inside Ollama.
- **Glue**: the code that decides *what* to compute next: cut audio into blocks, pick a language, loop over
  tokens, merge speakers, write JSON. Here: our ~5,100 lines of Python plus the Python parts of mlx-whisper and
  pyannote.

Python is slow per instruction (~50-100x slower than Rust for a tight loop) but our glue does very few
instructions per second of audio. Example: one whisper decoder step on the GPU takes milliseconds; the Python that
schedules it takes well under a millisecond, and mlx-whisper already overlaps the two (`mx.async_eval` in
`mlx_whisper/decoding.py`: Python prepares step *n+1* while the GPU computes step *n*). Making the conductor
faster does not make the orchestra play faster.

Rule of thumb: a rewrite pays off when a profile shows most time in *Python frames*. Ours shows (by code reading
and the stage timings) most time in *native frames*.

## 3. Where time goes today

Post-Stop wall time for a 1 h two-track meeting, from the learned per-stage factors in
[`realtime-feasibility.md`](realtime-feasibility.md) section 5 (today = 1,792 s ≈ 30 min). Caveat: those factors are
EMAs from 40-290 s meetings measured under memory pressure "warn" with 16-20 GB swap, extrapolated to 1 h; fixed
costs (model load) are amortized over short audio, so the 1 h figures likely overstate diarize/transcribe.

```
1 h meeting, after Stop (≈ 30 min)                                  engine (language)
prepare    ██                                     54 s   3 %   ffmpeg (C)
diarize    ██████████████████████████████████   899 s  50 %   pyannote -> PyTorch MPS (C++/Metal)
transcribe ████████████████████████████         733 s  41 %   mlx-whisper -> MLX (C++/Metal)
summarize  ████                                 105 s   6 %   Ollama (Go) -> llama.cpp (C++/Metal)
render+finalize                                  <1 s   0 %   Python

Inside each bar (est):  ▓ kernels / native code  ≥ 90 %   ░ Python glue ≤ 5-10 %   · load/startup, I/O, IPC ≤ 1-2 %
```

### 3.1 Split by cost type

| Cost type | Where it happens | Size for 1 h | Evidence |
|---|---|---|---|
| Model compute (GPU/ANE/CPU kernels) | whisper encoder + decoder (MLX), pyannote segmentation + embeddings (MPS), llama.cpp | ~1,650-1,700 s, **> 90 %** | [est] from stage factors; RTF 0.16-0.18 for turbo [local] |
| Python glue | block building, VAD (numpy), language choice, filters, pyannote aggregation, clustering driver | tens of seconds, **≤ 5 %** | [est] code reading; numpy/scipy calls are C |
| Model load / import | `import torch, pyannote.audio` (seconds), weight load (whisper q4 464 MB, pyannote 34-61 MB), Metal/MPS kernel compile | ~5-15 s per meeting, **< 1 %** | [est]; the `warmup` command exists to pre-pay it |
| I/O | 16 kHz PCM_16 WAVs (~115 MB per track per hour), JSON files | ~1-2 s | [est]; SSD-bound, native code (libsndfile) |
| ffmpeg | decode sources, encode 3 AAC listening copies | 54 s (prepare) | [local] stage factor; already C |
| Process spawn | `uv run meeting-notes worker` | 0.07 s warm, 0.24 s cold | [local] `uv run --offline meeting-notes --help` (3 runs) |
| Python start + CLI import | interpreter + `meeting_notes.entrypoints.cli` (heavy libs lazy) | 0.03 s + 0.026 s | [local] `python -X importtime` |
| IPC | JSON lines on stdin/stdout, a few events per second | microseconds | [est] |
| Swap / memory pressure | page-outs while models and Ollama are resident | unknown, possibly the largest hidden cost | 4.9 M page-outs, pressure "warn" today [local] |

### 3.2 What the engines spend time on

**Transcribe (mlx-whisper, `adapters/outbound/mlx_transcriber.py`, `application/transcribe_blocks.py`).**
Whisper always encodes a 30 s window, even for a 3 s block. Per block we pay that twice: `detect_language()`
builds a padded mel and runs the encoder, then `mlx_whisper.transcribe()` builds the mel again and runs the
encoder again before decoding. `split_by_language` adds more detection calls on sub-turns. The feasibility study
measured a **fixed floor of ~1.4-1.6 s per call** [local], so many short blocks cost far more than their audio.
This is algorithmic, and a Rust caller would pay exactly the same encoder passes.

**Diarize (pyannote community-1 on MPS, `adapters/outbound/pyannote_diarizer.py`).** The segmentation model slides
a 10 s window with a 1 s step (each second of audio is seen ~10 times), then a ResNet34 speaker embedding runs per
(window, local speaker), batched 8 at a time (`diarization_batch_size = 8`, chosen for shorter GPU bursts), then
clustering in numpy/scipy. **Both tracks are diarized in full** (`application/diarize_tracks.py`), although the
mic track usually holds one voice. Threads are capped at 4 and the process runs at nice 10 + utility QoS, by
design. Vendor tables put pyannote on MPS at 20-25x real time [V]; we see ~4x per meeting-second (two tracks,
low priority, swap). Again, nothing here is Python-bound.

**Summarize.** Python sends HTTP requests to Ollama and merges JSON. Ollama is already Go with a C++ engine.

## 4. Stage by stage: does Go or Rust change it?

| Stage / cost | Go | Rust | What actually changes it |
|---|---|---|---|
| prepare (ffmpeg) | No | No | Have Swift write 16 kHz WAV directly, or AVFoundation instead of ffmpeg; encode m4a in the background |
| diarize compute | No | No, unless it unlocks a faster port (speakrs, pyannote-rs) | Engine: Core ML/ANE (FluidAudio, speakrs) or ONNX Runtime (sherpa-onnx); skip mic-track pyannote |
| transcribe compute | No | No | Algorithm: one encoder pass per block, batching blocks; engine choice (MLX is already the fastest measured Whisper path on Mac [B]) |
| summarize | Already Go | n/a | Model size, context, prompt (see `speed-memory.md` section 3) |
| Python glue | ~ -1-5 % | ~ -1-5 % | Not worth a rewrite on its own |
| Import / load | -2-8 s per meeting | -2-8 s per meeting | Warm worker (`warmup`, `keep_models_warm`); overlap load with `prepare` |
| Spawn, IPC, I/O | ~0 | ~0 | Already negligible |

### 4.1 Realistic native options

| Component | Option | Language binding | Speed vs today | Notes |
|---|---|---|---|---|
| ASR | whisper.cpp (Metal, optional Core ML encoder) | Rust `whisper-rs` (`metal` feature; repo moved to Codeberg), Go `bindings/go` (cgo) in the whisper.cpp repo, Swift package | **Equal or slower**: mlx-whisper 1.02 s vs whisper.cpp 1.23 s on a short clip (M4), ~2x faster on a long file [B] | Same weights (ggml), small quant loss; Core ML encoder needs a one-time slow ANE compile on first run |
| ASR | WhisperKit (Swift, Core ML/ANE) | Swift only | 2.22 s for large-v3 (not turbo) on the same clip [B] | Value is moving work off the GPU (call running), not raw speed; vi quality untested (`realtime.md` T1) |
| ASR | mlx-swift | Swift | Same kernels as today (MLX) | Whisper port is community-maintained [gap] |
| ASR | candle (Rust, Metal) / burn (Rust) | Rust | Unknown; generally behind MLX/whisper.cpp on Apple GPUs [gap] | ML frameworks still maturing; most work for least certainty |
| Diarization | speakrs (Rust, community-1 on ONNX Runtime or Core ML) | Rust | 529x vs pyannote 24x real time, DER 7.1 vs 7.2 % VoxConverse [V] | Self-reported, English corpora, young crate (docs.rs build failed for 0.4.0) |
| Diarization | pyannote-rs (segmentation-3.0 + wespeaker on ONNX Runtime, Core ML EP) | Rust | Fast on CPU [V, no numbers] | Cosine matching only, no VBx/PLDA: weaker speaker counting |
| Diarization | sherpa-onnx (segmentation-3.0 + 3D-Speaker/WeSpeaker ONNX) | C++ core with **Python**, Go, Swift and other bindings | Fast on CPU [V, gap on Mac] | Threshold or fixed-count clustering, no PLDA |
| Diarization | FluidAudio (Swift, Core ML port of community-1) | Swift | 65-122x real time on ANE [V] | Off the GPU; parity with pyannote on vi untested |
| Summary | Ollama | already Go + llama.cpp | none | Nothing to rewrite |

The fastest diarization ports happen to be native code, but their speed comes from **Core ML/ANE and a leaner
pipeline**, not from Rust. The same speakrs result would show up if a Python process called the same Core ML model.
That is the main lesson: **pick the engine first; the host language follows from what bindings exist.**

### 4.2 "No backend": Swift calls the engines directly

The app is already Swift. WhisperKit or whisper.cpp (Swift package) for ASR, FluidAudio for diarization and plain
HTTP to Ollama would remove the Python worker, `uv` and the JSON-lines protocol. This is option D of
[`one-click-install.md`](one-click-install.md) (4-8 weeks). It is the only "native" variant that removes a whole
runtime instead of adding a third language. It breaks the frozen app-pipeline contract (AGENTS rule 5), loses the
pure-Python domain tests and the bench harness, and every engine needs a vi/code-switch re-benchmark.

## 5. Cheaper Python-side wins (ranked)

| # | Change | Expected gain | Effort | Risk |
|---|---|---|---|---|
| 0 | **Measure cleanly first**: one real 30-60 min meeting, memory pressure normal, Ollama unloaded, `/usr/bin/time -l`, `status.json` timings, `vm_stat` before/after | Tells whether swap or compute dominates | 0.5 day | none |
| 1 | **Mic track: VAD + embedding check instead of full pyannote** when `mic_speakers = "me"`, or when a quick embedding check finds one voice | Up to ~half of diarize (≈ 20-25 % of total) [est] | 1-2 days | In-person meetings need the full path; keep it on a threshold |
| 2 | **Faster diarization engine behind the existing `Diarizer` port**: sherpa-onnx (Python wheel), or a FluidAudio/speakrs helper CLI that returns turns as JSON | Diarize 2-20x faster [V]; with A (live) post-Stop drops to 19-34 % of today ([`realtime-feasibility.md`](realtime-feasibility.md) table) | 2-5 days | DER on vi meetings must be checked (`speed-memory.md` diarize bench) |
| 3 | **One encoder pass per block**: compute the mel/encoder output once, detect language from it, decode with it (needs a small mlx-whisper call path of our own) | Up to ~30-40 % of transcribe on short blocks [est] | 2-3 days | Touches the vendored call path; covered by `asr_bench` |
| 4 | **Batch blocks** (decode several VAD chunks per encoder batch, WhisperX style) | Further transcribe gain [gap] | 3-5 days | Prompt/language per block must stay correct |
| 5 | **Overlap model load with `prepare`** (warm whisper/pyannote while ffmpeg runs) | 5-15 s per meeting | 0.5 day | More RAM earlier |
| 6 | `diarization_batch_size` 32 when "idle and plugged in" | Small [gap] | trivial | Longer GPU bursts |

## 6. Secondary benefits and costs of going native

| Aspect | Python today | Rust/Go sidecar (whisper.cpp + ONNX) | Swift-native (WhisperKit/whisper.cpp + FluidAudio) |
|---|---|---|---|
| Processing speed | baseline | ≈ same (engine-bound); diarize faster only via a new engine | ≈ same ASR; diarize faster (ANE) |
| Startup to first inference | 0.1 s spawn + seconds of `torch`/`pyannote` import + weight load | ms + weight load + Metal compile | same as Rust; Core ML first-run compile can take minutes once |
| Baseline RAM | Python + torch runtime, a few hundred MB [est]; peak RSS 0.75-1.1 GB [local] | lower by ~0.2-0.5 GB [est]; model memory unchanged | similar to Rust; ANE memory not counted as GPU |
| Install size | 1.4 GB venv (torch 574 MB, mlx 174 MB, scipy 90 MB) [local] + `uv` + Python | ~30-80 MB binary + dylibs [est] | inside the app, ~20-60 MB [est] |
| One-click install | needs `uv` sync at first run (≈ 0.35 GB download) | ships in the dmg | ships in the dmg |
| Crash safety | worker crash isolated from the app (separate process) | same if kept as a process | an engine crash takes down the recorder unless put in an XPC helper |
| Dev speed | fast iteration, numpy, rich ML ecosystem, pytest | slower; ML glue (resampling, VAD, clustering) rewritten by hand | slower; Xcode builds; fewer ML libraries |
| Ecosystem gaps | none (pyannote, mlx-whisper first-class) | **pyannote has no official native port**; VBx/PLDA clustering missing in sherpa/pyannote-rs; speakrs young | FluidAudio is a port; quality parity unproven on vi |
| Quality risk | measured baseline | re-benchmark ASR (ggml quant) and DER | re-benchmark ASR (Core ML) and DER |
| Effort | - | 4-8 weeks: port ~3,000 lines of domain/application logic + ~2,100 adapter/entrypoint lines, tests, benches | 4-8 weeks (`one-click-install.md` option D) |
| Languages in the repo | 2 (Swift, Python) | 3 (Swift, Python for benches, Rust/Go) | 1 (+ Python for benches if kept) |

Go is the weaker of the two native choices here: its ML ecosystem is thin, cgo calls add overhead and complicate
cross-compiling, and its GC adds pauses around large buffers. Its strength (network services) is already covered by
Ollama. Rust has better bindings (whisper-rs, ort, speakrs, pyannote-rs, candle) but still adds a third language.

## 7. Learning path: a one-day spike

Goal: see with your own eyes that the time lives in the engine, and compare two engines on the same audio.
Do it on a synthetic fixture, never on `~/MeetingNotes`. Run only when `memory_pressure` says normal; quit Ollama
models first (`ollama ps`, then `ollama stop <model>`).

**Installs this spike needs (not done by this study):** `brew install whisper-cpp` (small), the ggml model
`ggml-large-v3-turbo-q5_0.bin` (~0.55 GB), optional `rustup` (~1 GB toolchain), optional `sherpa-onnx` wheel in a
throwaway env plus its ONNX models (~40 MB).

### Step 1: make a fixture and a baseline (1 h)

```bash
cd ~/meeting-notes/pipeline
memory_pressure | tail -1                                   # want "normal" / free >= 30 %
S=/tmp/mn-spike; rm -rf $S; mkdir -p $S
uv run python tests/e2e/make_synthetic.py $S                 # mic.wav (vi) + system.wav (en) + meeting.json
F="$S/2026-10-19 0900 Meeting"
printf 'keep_wav = true\n' > $S/spike.toml; export MEETING_NOTES_CONFIG=$S/spike.toml   # keep .work/*.16k.wav
/usr/bin/time -l uv run meeting-notes process "$F" 2> $S/baseline.time
grep -E "real|maximum resident" $S/baseline.time            # wall time, peak RSS
python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['timings'])" "$F/status.json"
```

Look for: which stage dominates, and peak RSS. `prepare` writes `.work/mic.16k.wav` and `.work/system.16k.wav`
(16 kHz PCM_16, exactly what whisper.cpp wants); `keep_wav` stops `finalize` from deleting them. The folder may be
renamed to the generated title at finalize: re-set `F` to the new folder name (`ls $S`).

### Step 2: see glue vs kernels in a profile (1 h)

```bash
uv run python -m cProfile -o $S/transcribe.prof -m meeting_notes.entrypoints.cli process "$F" --from transcribe
uv run --with snakeviz snakeviz $S/transcribe.prof           # or: python -m pstats $S/transcribe.prof, then "sort tottime", "stats 20"
```

How to read it: sort by `tottime` (time spent *in* the function itself). Native calls show up as
`{built-in method ...}`, `mlx.core.*` or `eval`; our Python functions should have tiny `tottime` and large
`cumtime` (they wait on native code). If a pure-Python function sits near the top of `tottime`, that is the only
code a Rust rewrite would speed up. (`py-spy record --native` gives a flame graph too, but needs `sudo` on macOS.)

### Step 3: same audio through whisper.cpp (2 h)

```bash
brew install whisper-cpp                                      # provides whisper-cli
curl -L -o $S/ggml-turbo-q5.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
/usr/bin/time -l whisper-cli -m $S/ggml-turbo-q5.bin -f "$F/.work/mic.16k.wav" -l vi -otxt -of $S/wcpp_mic 2> $S/wcpp.time
grep -E "real|maximum resident" $S/wcpp.time; grep -E "load time|encode time|decode time|total time" $S/wcpp.time
```

whisper.cpp prints its own split (load, mel, encode, decode, total): a direct view of model load vs encoder vs
decoder. Compare against the `transcribe` stage. Then compute WER against the fixture script with our metric:

```bash
uv run python -c "
import sys; from meeting_notes.domain.metrics import wer
ref = open(sys.argv[1]).read(); hyp = open(sys.argv[2]).read()
e, n = wer(ref, hyp); print(f'WER {e}/{n} = {e/n:.3f}')" ref_mic.txt $S/wcpp_mic.txt
```

(`ref_mic.txt` = the `mic` lines of `SCRIPT` in `tests/e2e/make_synthetic.py`; do the same for the pipeline's
`transcript.json` mic segments.)

What to look for: wall time within ±30 % of MLX (expected, same model), peak RSS, whether Vietnamese diacritics and
English terms survive, and that **load time** is a visible chunk of a short clip but tiny for a long one.

### Step 4 (optional): the Rust version is just a thin caller (2 h)

```bash
cargo new wspike && cd wspike && cargo add whisper-rs --features metal && cargo add hound
```

A ~30-line `main.rs` (read WAV with `hound`, `WhisperContext::new_with_params`, `create_state`, `full(params, &samples)`,
print segments; API names vary by crate version, check docs.rs) runs the **same C++ kernels** as `whisper-cli`.
Its time should match Step 3 within noise. That is the core lesson in one measurement.

### Step 5 (optional): a different diarization engine from Python (2 h)

In a throwaway env (`uv venv $S/sherpa && uv pip install --python $S/sherpa sherpa-onnx`), run sherpa-onnx's
offline speaker-diarization example on `.work/system.16k.wav` with the pyannote segmentation-3.0 ONNX model and a
3D-Speaker embedding model (download links in the sherpa-onnx docs). Compare its wall time and speaker count with
the `diarize` stage. A big speedup here, still from Python, shows that **engine choice, not language**, moves the
needle.

### What to write down

| Run | Wall s | Peak RSS GB | WER mic | Speakers found | Load s |
|---|---|---|---|---|---|
| pipeline (MLX + pyannote) | | | | | |
| whisper-cli turbo q5_0 | | | | n/a | |
| whisper-rs (optional) | | | | n/a | |
| sherpa-onnx diarization (optional) | | | n/a | | |

## 8. Recommendation

1. **Do not rewrite the pipeline in Go or Rust for speed.** Expected gain ~1-5 %, cost 4-8 weeks plus quality risk.
2. **Now:** run the clean measurement (section 5, #0) on a real 30-60 min meeting; then do #1 (mic-track shortcut)
   and #3 (single encoder pass). Both are Python-only and target the two stages that are 91 % of the time.
3. **Next:** benchmark a faster diarizer behind the `Diarizer` port (sherpa-onnx from Python, or a FluidAudio /
   speakrs helper CLI returning JSON). Adopt only if DER on vi meetings is within 2 pp and it is >= 5x faster
   (thresholds from `speed-memory.md`).
4. **Later, if one-click install or footprint becomes the main goal:** go Swift-native (option D) rather than Rust
   or Go: one language, first-class Core ML/ANE, no Python runtime to ship.
5. **For learning:** the one-day spike in section 7.

Sources (accessed 2026-10-23): whisper.cpp https://github.com/ggml-org/whisper.cpp ; whisper-rs
https://rust-digger.code-maven.com/crates/whisper-rs ; pyannote-rs https://rust-digger.code-maven.com/crates/pyannote-rs ;
speakrs https://docs.rs/speakrs ; polyvoice https://docs.rs/crate/polyvoice ; sherpa-onnx diarization via LocalAI
https://localai.io/docs/features/audio-diarization/ ; plus the sources cited in `speed-memory.md` (mlx-whisper vs
whisper.cpp, FluidAudio benchmarks).
