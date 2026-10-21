# Speed and memory research: meeting-notes pipeline

Date: 2026-10-20. Scope: ASR, diarization, summary, pipeline tricks on Apple Silicon (16 GB).
Labels: **[V]** = vendor/self-reported claim, **[I]** = independent/third-party or peer-reviewed, **[B]** = blog single-machine run (weak). "Gap" = not found in search; must be measured locally.
Limitation: the LinkedIn post (https://www.linkedin.com/feed/update/urn:li:activity:7517605946701811712/) could not be fetched (login wall / socket closed). A topic search found only generic pages about Parakeet + FluidAudio local meeting apps (https://blog.buildbetter.ai/best-local-ai-meeting-recorders-no-cloud-2026/, 2026). Its content is unverified here.
Searches were one-shot and shallow; many cells below are gaps, not negatives.

## TL;DR (ranked)

1. **Replace pyannote-on-MPS with FluidAudio Core ML diarization (ANE).** Speed: 65-122x RTFx vs pyannote community-1 20-25x on MPS [V, same vendor doc]. Memory: moves work off the GPU/MPS, frees ~2 GB unified memory pressure. Quality: DER 13.9-15.1% AMI SDM [V], roughly within 1% of pyannote [V]; a Rust Core ML port of pyannote shows 7.1% vs 7.2% DER at 22x speedup [V, VoxConverse]. Risk: medium (Swift package, new integration, Vietnamese speaker embeddings untested; must validate DER on own meetings).
2. **Cap MLX memory and stop per-block ASR overhead**: `mx.set_cache_limit` (e.g. 512 MB), `mx.clear_cache()` between blocks, VAD-segmented batched decode instead of per-speaker-block calls, run ASR and diarization sequentially (not parallel). Expected: peak 4 GB to about 2-2.5 GB (estimate, gap in published data), little speed change, no quality change. Risk: low.
3. **Streaming/incremental ASR during the meeting** (transcribe closed VAD chunks while recording, with a hard cap on GPU/CPU so call audio does not lag). Remaining post-Stop work shrinks to diarization + summary. Biggest UX win. Risk: high (call lag, mixed-language chunk boundaries). Only after 1-2.

Not recommended now: switching ASR to Parakeet (no confirmed Vietnamese), whisper.cpp (mlx-whisper faster), PhoWhisper (better vi, worse en/code-switch risk, no ready port found).
Also fix first: Ollama default `num_ctx` 4096 silently truncates long transcripts (see section 3).

## 1. ASR

| Engine | Speed (Apple Silicon) | Memory | Vietnamese | Notes / source |
|---|---|---|---|---|
| mlx-whisper turbo fp16 (current) | 1.02 s on a short clip, M4 24 GB [B]; 2.0x faster than whisper.cpp on a long file [B] | ~4 GB peak (own measurement; cache growth) | Vi FLEURS WER: turbo 9.48 vs large-v3 8.74 (Q8_0 run) [B] | https://notes.billmill.org/dev_blog/2026/01/updated_my_mlx_whisper_vs._whisper.cpp_benchmark.html (2026-01); https://github.com/anvanvan/mac-whisper-speedtest |
| whisper.cpp q5_0 + Core ML encoder | 1.23 s same clip, M4 [B]; ~2x slower than mlx on long file [B] | Gap (no peak RAM published) | Same weights, small quant loss (gap) | same two sources |
| WhisperKit (Argmax, Core ML/ANE) | 2.22 s on large-v3 (not turbo), M4 [B]; vendor claims 5.2x on iPhone 15 Pro [V] | Gap | Gap | https://github.com/anvanvan/mac-whisper-speedtest; https://www.promptlayer.com/models/whisper-large-v3-turbo |
| mlx-whisper 4/8-bit quant, lightning-whisper-mlx | Gap (no numbers found) | Expect weights ~0.4-0.8 GB (estimate) | Quant WER impact unknown, test on vi | |
| distil-whisper | 30-40% faster than whisper.cpp on M1 Pro (distil-large-v3) [B] | smaller | English-only; unsuitable for vi | https://simonwillison.net/2024/Aug/13/mlx-whisper |
| faster-whisper / CTranslate2 | CPU-only on Mac, slower than Metal paths (no number found) | Gap | same weights | |
| Parakeet TDT 0.6B v3 (parakeet-mlx / Core ML) | ~110x RTF M4 Pro Core ML [V]; ~68x implied for parakeet-mlx [V, hardware unspecified]; 1h audio ~53 s | small | **Not supported**: v3 covers 25 European languages [V] | https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml; https://www.skills.sh/clawdbot/skills/parakeet-mlx |
| PhoWhisper large (VinAI) | Same architecture as Whisper large-v3 (slower than turbo) | ~3 GB fp16 | Vi WER: CMV 8.14, VIVOS 4.67, VLSP-1 13.75, VLSP-2 26.68 [I, paper] | https://arxiv.org/pdf/2406.02555 |
| PhoWhisper-large LoRA code-switch fine-tune | n/a | n/a | 4.56% WER-N on its own vi-en holdout vs 20.95% baseline [V, self-published]; -2.59 pp on VIVOS | https://huggingface.co/rinhoooo/phowhisper-large-vien-cs-asr |

Quality evidence:
- Turbo vs large-v3 on English leaderboard: mean WER 7.83 vs 7.44 [I] (https://www.promptlayer.com/models/whisper-large-v3-turbo, aggregator of HF Open ASR Leaderboard).
- Vi-en code-switch (TSPC paper, table headers garbled, approximate): whisper-large-v3-turbo 31.60 WER vs PhoWhisper-base 27.90 on code-switch, 45.23 vs 14.05 on Vietnamese average [I]. Implies turbo is weak on Vietnamese; PhoWhisper family likely better on vi, and may need LoRA for English insertions. https://arxiv.org/pdf/2509.05983
- Code-switch benchmark: Vietnamese-optimized models win on general segments, multilingual pretraining helps English insertions [I] https://arxiv.org/pdf/2602.12911
- Vietnamese Open ASR Leaderboard exists (not parsed): https://vietaudio-team-vietnamese-asr-leaderboard.hf.space/
- Gaps: PhoWhisper GGML/MLX ports (convert-h5-to-ggml.py exists for HF fine-tunes, PhoWhisper compatibility unverified: https://raw.github.com/ggerganov/whisper.cpp/master/models/convert-pt-to-ggml.py); VAD-batched long-form (WhisperX-style) speed numbers on Mac.

Take: keep mlx-whisper (fastest measured Whisper path on Mac [B]). The quality lever for Vietnamese is the model (PhoWhisper-large via mlx conversion, own WER test), not the runtime. The speed lever is shrinking memory and removing per-block overhead.

## 2. Diarization

| Option | Speed | Memory | DER | Source |
|---|---|---|---|---|
| pyannote community-1 (current, MPS) | 20-25x RTFx MPS, 1.5-2x CPU [V, FluidInference table] | ~2.2 GB (own) | 7.2% VoxConverse dev [V, speakrs] | https://docs.fluidinference.com/reference/benchmarks |
| FluidAudio Core ML (ANE) | 122x default, 65x max-accuracy, M2 [V] | Gap, off-GPU | 15.1% / 13.9% AMI SDM [V]; within ~1% of PyTorch [V]; streaming 10-15% worse [V] | https://docs.fluidinference.com/reference/benchmarks ; https://huggingface.co/FluidInference/speaker-diarization-coreml/blob/main/README.md |
| speakrs (Rust, pyannote community-1 on Core ML) | 529x vs pyannote 24x [V] | Gap | 7.1% vs 7.2% VoxConverse [V] | https://docs.rs/speakrs |
| NeMo Sortformer (Core ML via FluidAudio) | 126.7x RTFx [V] | Gap | 31.7% AMI SDM avg [V]; max 4 speakers; chunking needed beyond ~12 min [I] | https://docs.fluidinference.com/diarization/sortformer ; https://arxiv.org/html/2509.26177v1 |
| DiariZen | Gap | Gap | 13.3% avg across datasets vs pyannoteAI 11.2% [I] | https://arxiv.org/html/2509.26177v1 |
| sherpa-onnx (pyannote seg ONNX + 3D-Speaker/WeSpeaker) | Gap (no numbers found) | Gap | Gap | FluidAudio author says it works but slowed older devices alongside ASR (anecdote) https://hn.svelte.dev/item/44546863 |

Take: speakrs/FluidAudio-style Core ML pyannote ports give pyannote-level DER at 20x+ speed. Sortformer is worse (DER, 4-speaker cap), skip. Meeting audio here is two tracks (mic vs system), so "you" is already known; diarization is only needed on the system track, which lowers cost and DER risk further. Vendor claims are on English corpora; verify on vi meetings.

## 3. LLM summary

| Option | Evidence |
|---|---|
| Ollama qwen3:4b (current) | Default `num_ctx` 4096 silently truncates longer prompts; the OpenAI-compatible endpoint may ignore per-request `num_ctx`, set `OLLAMA_CONTEXT_LENGTH` or a Modelfile [B] https://fast.io/resources/ollama-context-window/ ; https://www.autodidacts.io/increase-ollama-context-length-num-ctx/. Vietnamese tokenizes longer, so a 1 h transcript needs chunking (map-reduce) or large ctx (KV cache cost on 16 GB). Check the repo's current setting. |
| MLX-LM vs llama.cpp vs Ollama | Qwen3-4B 4-bit M4 Max: MLX 159 tok/s vs llama.cpp 118 (+35%) [B, secondary]; M1 Max: mlx-lm 49.6 vs Ollama 45.4 (different model builds) [B]. Differences are modest at 4B; prompt processing (prefill) dominates for long transcripts and was not measured. https://blog.starmorph.com/blog/apple-silicon-llm-inference-optimization-guide ; https://bright-lotus-8q5y.here.now/ |
| Quant levels (Q4_K_M vs Q5/Q8, MLX 4-bit) | No Vietnamese-specific data found (gap). |
| Qwen3-4B-Instruct-2507 / Gemma 3 4B | No head-to-head Vietnamese summary result found. Gemma 3 4B: 128K ctx, 140+ languages [V, model card via https://www.jetson-ai-lab.com/models/gemma3-4b]. Must test locally. Qwen3 thinking mode: ensure disabled (`/no_think`) for speed. |
| Speculative decoding | No Mac small-model numbers found; low value for 4B. |

Take: the cheapest win is correctness (ctx, no-think), then try MLX-LM 4-bit and Qwen3-4B-Instruct-2507 in `summary_bench.py`. Expect speed gains of 10-35% [B], not 2x.

## 4. Pipeline tricks

- **Sequential vs parallel under 16 GB:** run ASR then diarization (not parallel) unless diarization is on ANE (Core ML), where parallelism does not compete for GPU memory. Unload each model before the next; release MLX cache. No published data; measure.
- **`mx.set_cache_limit` / `mx.clear_cache`:** MLX API for bounding the Metal buffer cache. No published peak-RSS numbers for whisper found (gap); check against the MLX docs https://ml-explore.github.io/mlx/ before use. This directly targets the 4 GB peak.
- **Decode per speaker block:** many short calls re-run encoder padding to 30 s. VAD-chunked decode (batch several chunks) or decode full track once and assign speakers by word timestamps is expected to cut encoder work substantially (estimate). Word timestamps cost extra; measure.
- **Streaming during the meeting:** transcribe each closed VAD segment (10-30 s) on a low-priority process with `set_cache_limit`; only the final tail plus diarization+summary after Stop. Constraint: Zoom/Meet on the same machine, so throttle (nice, pause under memory pressure, or ANE-only engine). Core ML Whisper (WhisperKit) on ANE is the natural fit for background load; unverified here.
- Swap pressure is the likely root cause of the 20-30 min for 1 h. Step zero: record `memory_pressure`/swap during a run.

## 5. Benchmark plan (this machine)

Common: 3 real or consented meetings (30 min vi-heavy, 30 min en, 30 min code-switched) with manually corrected reference transcripts (use a 10 min excerpt each to limit labeling). Record per stage: wall time, peak RSS (`/usr/bin/time -l`), peak Metal memory (`mx.get_peak_memory()`), swap delta (`vm_stat` before/after), run under "Zoom open" and idle conditions. Run 3 times, report median.

Extend `pipeline/bench/asr_bench.py` (currently synthetic TTS cases via `say()`/`make()`, variants run through `run()`/`run_all()`):
1. Add a `--real <dir>` mode: audio + `ref.txt` pairs; compute WER (jiwer, NFC-normalized, lowercase, punctuation stripped) overall and split by language tag (vi spans vs en spans) for code-switch error rate.
2. Add variants: `mlx-turbo-fp16` (baseline), `mlx-turbo-capped` (`set_cache_limit`), `mlx-turbo-4bit/8bit`, `mlx-large-v3`, `phowhisper-large-mlx` (convert HF to MLX), `whispercpp-q5_0-coreml` (subprocess), `vad-batched` vs `per-speaker-block` decode.
3. Log peak memory and RTF for each variant to JSON for comparison.
Extend `summary_bench.py` (`--model`, `--impl`, `--cases`, `--runs`, `--out`): add `--backend ollama|mlx-lm|llamacpp`, `--num-ctx`, a long-transcript case (1 h vi) to expose truncation, and log prefill + decode tok/s. Candidates: qwen3:4b Q4_K_M, Qwen3-4B-Instruct-2507, gemma3:4b, MLX 4-bit builds. Score with the existing `score()` plus a human-blind A/B on 5 vi summaries.
New `diarize_bench.py`: DER via pyannote.metrics against hand-labeled system-track RTTM for 2 meetings; compare current pyannote-MPS, FluidAudio CLI, speakrs; also measure speaker-count accuracy and time-to-complete.
Decision thresholds: adopt ASR change only if vi WER improves or is within 1 pp absolute with >=30% less peak memory; diarization if DER within 2 pp and >=5x faster; summary if blind A/B non-inferior.

## 6. Open questions

- What did the LinkedIn post actually propose (engine, numbers)? Provide text or screenshot.
- Does FluidAudio/Parakeet have any Vietnamese model, or is a Swift helper binary acceptable inside the app bundle?
- Is PhoWhisper-large convertible to MLX cleanly, and does it handle English insertions without the LoRA fine-tune (whose card is self-published)?
- Peak memory of mlx-whisper with `set_cache_limit`, and quantized variants' vi WER (no published data found).
- How much of the 20-30 min is swap-thrash vs compute? Measure with a clean-memory run first.
- How much CPU/GPU headroom does a live call leave for background streaming ASR (ANE-only vs GPU)?
- Summary: is context truncation already handled by chunking in `application/summarize_meeting.py`?
- sherpa-onnx diarization speed/memory on Mac: not found, needs a direct test if Core ML route is rejected.
