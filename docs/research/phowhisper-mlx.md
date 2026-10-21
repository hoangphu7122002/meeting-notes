# PhoWhisper on MLX vs whisper-large-v3-turbo

Date: 2026-10-21. Question: should PhoWhisper (VinAI, Vietnamese fine-tune of Whisper) replace the default `mlx-community/whisper-large-v3-turbo`?

**Recommendation: keep turbo, quantized to 4 bits, as the default (`mlx-community/whisper-large-v3-turbo-q4`, adopted 2026-10-21). Do not route vi blocks to PhoWhisper yet.** On our benchmark PhoWhisper did not beat turbo on Vietnamese and was much worse on English and code-switched speech. The test set is small and synthetic (see limits), so this is "no evidence to switch", not "PhoWhisper is bad". Quantizing turbo to q4 cost nothing measurable here and cuts peak MLX memory from 2.3 GB to 1.2 GB; that is the more useful finding.

## Method

- Conversion: `pipeline/scripts/convert_phowhisper.py` turns a HF transformers Whisper checkpoint (`vinai/PhoWhisper-{small,medium,large}`) into the mlx-whisper format and can quantize (`--bits 4|8`, group size 64). The same script quantized turbo to q8/q4. Models live in `models/` (gitignored).
- Harness: `pipeline/bench/asr_bench.py` (`run|all <dir> <variant> --model <repo|path> [--vi-model <path>] [--label <name>]`). Each model runs in its own process (`nice 10`, 4 threads), full pipeline settings (`new` variant: VAD, glossary initial prompt, per-block language detection restricted to vi/en, temperature fallback). Models were run strictly one at a time.
- Corpus: 194 s synthetic audio from macOS `say` (vi voice Linh, en voices Samantha/Daniel), 23 blocks: 6 vi, 6 en, 6 vi/en code-switch (glossary terms: Kubernetes, Jira, Postgres, ...), one 40 s vi monologue, 3 noise-only blocks (room tone, keyboard) that must yield no text.
- Metrics: WER and CER on NFC, lowercased, punctuation-stripped text (`meeting_notes.metrics.words`; CER over the space-joined normalized string). RTF = ASR seconds / speech seconds. Memory: peak process RSS and peak MLX (Metal) memory from the run. "Terms" = glossary term recall.

## Results

WER/CER per category (lower is better). RTF and memory are for the whole 127 s speech corpus.

| Model | vi WER/CER | en WER/CER | code-switch WER/CER | vi monologue WER | all WER | term recall | RTF | peak RSS GB | peak MLX GB | size on disk |
|---|---|---|---|---|---|---|---|---|---|---|
| turbo fp16 (default) | 0.033/0.015 | 0.000/0.000 | 0.163/0.066 | 0.057 | 0.065 | 0.83 | 0.163 | 0.52 | 2.31 | 1.6 GB |
| turbo q8 | 0.033/0.015 | 0.000/0.000 | 0.163/0.066 | 0.057 | 0.065 | 0.83 | 0.175 | 1.04 | 1.61 | 0.8 GB |
| turbo q4 | 0.033/0.015 | 0.000/0.000 | 0.163/0.071 | 0.057 | 0.065 | 0.83 | 0.183 | 0.64 | 1.24 | 0.44 GB |
| PhoWhisper large fp16 | 0.275/0.271 | 0.730/0.504 | 0.300/0.162 | 0.057 | 0.311 | 0.62 | 0.311 | 0.84 | 3.67 | 2.9 GB |
| PhoWhisper large q8 | 0.275/0.271 | 0.667/0.490 | 0.275/0.142 | 0.045 | 0.289 | 0.62 | 0.266 | 1.73 | 2.34 | 1.5 GB |
| PhoWhisper large q4 | 0.209/0.186 | 0.746/0.534 | 0.275/0.149 | 0.057 | 0.289 | 0.55 | 0.306 | 1.05 | 1.63 | 0.84 GB |
| PhoWhisper medium fp16 | 0.110/0.087 | 1.111/0.813 | 0.400/0.281 | 0.068 | 0.366 | 0.38 | 0.160 | 0.78 | 2.07 | 1.4 GB |
| PhoWhisper medium q4 | 0.033/0.022 | 1.206/0.816 | 0.425/0.261 | 0.068 | 0.370 | 0.31 | 0.201 | 0.68 | 1.33 | 0.42 GB |
| PhoWhisper small fp16 | 0.374/0.275 | 1.063/0.831 | 0.487/0.273 | 0.148 | 0.475 | 0.21 | 0.117 | 0.40 | 1.35 | 0.46 GB |

Highest memory observed in the whole sweep: 3.67 GB MLX (PhoWhisper large fp16), RSS 1.73 GB (PhoWhisper large q8).

## Findings

- **Vietnamese:** only 6 short vi blocks + 1 monologue, so one dropped word moves WER by several points. Turbo scored 0.033 WER. PhoWhisper large (fp16/q8) dropped the start of short blocks (e.g. reference "Chào mọi người, hôm nay chúng ta họp nhanh về kế hoạch quý tới." decoded as "tới."), giving 0.275. PhoWhisper medium q4 tied turbo (0.033) while medium fp16 did not (0.110), so the spread between quantizations is noise on this corpus rather than a real quality ordering. On the 40 s monologue, PhoWhisper large equals turbo (0.057; q8 0.045).
- **English:** PhoWhisper is unusable for en blocks (WER 0.67-1.2). It transcribes English phonetically into Vietnamese ("sẽ sửa kết nối vào bug trước lễ kết"), or returns nothing. Turbo is perfect (0.000). Without a language-aware router, PhoWhisper would wreck English meetings.
- **Code-switch:** turbo 0.163 vs PhoWhisper large 0.275-0.300 and medium/small 0.40-0.49. English terms are phoneticized by PhoWhisper ("Kubernetes" -> "kube ronatex", "Jira" -> "uy ra", "retention" -> "ritaly sơn"); glossary term recall drops from 0.83 (turbo) to 0.62 (large) and 0.31 (medium q4). Turbo mostly keeps the English spelling.
- **Silence/noise:** 0 hallucinated words for every model on the 3 noise-only blocks (VAD filters them before decoding). Real room audio was not tested.
- **Quantization:** turbo q8/q4 are indistinguishable from fp16 on this corpus (identical WER; code-switch CER 0.066 -> 0.071 for q4). Speed is ~10-12% slower (RTF 0.163 -> 0.175/0.183, dequantization overhead), peak MLX memory falls 2.31 -> 1.61 -> 1.24 GB.
- **Speed:** PhoWhisper large is ~1.6-1.9x slower than turbo (RTF 0.27-0.31 vs 0.16), as expected from the 32-layer decoder.
- A possible cause of the large-model truncation is the glossary `initial_prompt` the pipeline always passes (a fine-tune on short utterances may react badly to a prompt prefix). A no-prompt rerun was planned but not run (see Skipped).

## Limits

- Synthetic TTS speech only: clean, single voice per language, no overlap, no accents. Real meeting audio may favour PhoWhisper's Vietnamese training data more than this shows. 6 vi blocks are too few for fine ranking.
- English and code-switch blocks were decoded by PhoWhisper only because language detection came from the same model; the vi-only routing variant (detect + en with turbo, vi with PhoWhisper) was not measured.

## Skipped

The machine ran out of swap, so the sweep was stopped at the coordinator's request. Not run:
- PhoWhisper without the glossary prompt (`vad` variant) on large fp16/q8 and medium q4, plus turbo without prompt, to test the truncation hypothesis.
- Routed runs (`--vi-model`: turbo for detection and en, PhoWhisper large q8 / medium q4 for vi blocks). The routing support in `asr_bench.py` is implemented but untested.

## If revisited

1. Re-run the skipped no-prompt and routed variants on a larger real vi meeting sample (human reference transcript), 10+ min of vi.
2. Per-block routing would need pipeline code: `whisper_model` is one model today. Detection with turbo, vi blocks to PhoWhisper large q8 (1.5 GB, ~2.3 GB MLX) keeps English intact, at the cost of loading two models (~1.6 + 1.5 GB) or swapping them per block.
3. Done: turbo q4 is the default. The published `mlx-community/whisper-large-v3-turbo-q4` (weights.npz, group size 64) loads with mlx-whisper 0.4.3 and scored the same as the local conversion on this corpus (WER all 0.065, vi 0.033, en 0.000, code-switch 0.163, CER code-switch 0.073 vs 0.071; peak MLX 1.24 GB). A missing local `whisper_model` path falls back to fp16 turbo with a warning.
