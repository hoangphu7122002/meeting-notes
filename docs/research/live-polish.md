# Live transcript polish: design study

Date: 2026-10-23. Status: **research and design only, nothing built.** Machine: M1 Pro, 16 GB, macOS 15.5,
memory pressure often "warn" with 16-20 GB swap (see [`realtime-feasibility.md`](realtime-feasibility.md)).
Builds on live transcription design A ([`realtime.md`](realtime.md)): turbo q4 decodes one VAD chunk at a
time, partials go to `.work/transcript.partial.jsonl` and to the pill as `live_segment` events.
Labels as in the other research docs: **[V]** vendor claim, **[I]** peer-reviewed, **[B]** blog / community
run, **[local]** measured here, **[est]** estimate. No local LLM probe was run: memory pressure was level 2
(warn) when this was written, so every latency below is external or estimated.

## 1. Request and what it can mean here

Request: while recording, show a live transcript that is also corrected in real time (grammar, punctuation,
sentence structure, paragraphs), Vietnamese + English with code-switching, balancing accuracy and latency.

Facts that shape the answer:

1. **Live text is already 10-35 s behind speech** (design A cuts at pauses, 4-28 s chunks, plus ~1.5 s
   decode floor) [local]. No polish tier can be faster than the chunk it polishes; "real time" here means
   "shortly after the chunk arrives", not word-level captions.
2. **Whisper turbo already emits punctuation and casing.** The visible problems in live text are mostly
   chunk-boundary effects (a sentence split across two chunks, a lowercase or capitalized fragment start,
   a missing final period), run-on sentences in long chunks, fillers and repeats, glossary casing, and
   occasional ASR word errors (vi tone confusions, phoneticized English terms). Only the last one needs
   word changes; it is also the riskiest to touch.
3. **The final transcript after Stop is authoritative** (offline path or strict reuse of partials). Polish is
   a display layer and must never feed `transcript.json`, notes or the summary.
4. **Constraints:** local only (Ollama or on-device, AGENTS.md rules 1-2); one heavy job at a time at low
   priority; RAM is the binding resource (whisper turbo q4 1.24 GB MLX peak [local] + a video call + an
   LLM).

## 2. Survey (2025-2026)

### 2.1 LLM post-editing of ASR output

- Generative error correction (GER) beats N-best reranking when the LLM is fine-tuned on ASR hypotheses:
  HyPoradise [I, NeurIPS 2023], Whispering LLaMA (audio-fused, 28-38 % relative WER gain vs N-best oracle
  [I, EMNLP 2023]), Clarispeech (12 % to 10 % WER with a frozen ASR + fine-tuned LM [B/preprint, 2025]).
  All are fine-tuned, mostly English, and run larger models than fit here.
- **Zero-shot small LLMs tend to over-correct.** A 2026 EACL short paper (Hindi post-ASR correction) finds
  smaller fine-tuned models beat larger LLMs, and mid-sized LLMs *degrade* WER under zero-shot prompting
  [I]. A 2024 study warns that sending every hypothesis to the LLM introduces errors into correct sentences
  and gates correction by Whisper confidence [I/preprint]. Both point to: gate by confidence, constrain the
  edit, verify.
- **Edit-based output** (predict compact phrasal rewrites instead of a full rewrite) cuts output tokens and
  limits drift; it was designed for correcting streaming first-pass ASR [I/preprint, 2025].
- Vietnamese: no 2025-2026 paper found on LLM correction of tone marks in ASR output; the closest work is OCR
  post-correction and a tonal-confusion error class in vi speech translation (PiDA, unverified) [gap].
  Diacritic restoration is hard (WER > 40 % on fully stripped text in older work [I]); a tone change is a
  different word, so "fixing" tones by context is a meaning change, not formatting.

### 2.2 Small local models on M1 Pro (latency, RAM)

| Model (Ollama tag) | Disk (Q4) | Resident, ctx 2k [est] | Decode tok/s M1 Pro | Prefill tok/s | Notes |
|---|---|---|---|---|---|
| `gemma3:1b` | ~0.8 GB [V] | ~1.1-1.3 GB | ~60-90 [est] | ~600+ [est] | 140+ languages [V]; vi quality unknown |
| `qwen3:1.7b` | ~1.4 GB [V] | ~1.7-2.0 GB | ~45-60 [est]; 24 [B, generic estimate site] | ~400-500 [est] | 100+ languages [V]; needs `think: false` |
| `qwen3:4b` (installed) | 2.5 GB [local] | ~3.0 GB | 27-35 [B, oMLX Qwen3-4B-2507 on M1 Pro 16 GB] | 200-280 [B] | current summary model |
| viBERT-capu (`dragonSwing/vibert-capu`) | ~0.45 GB fp32 [est, BERT-base] | ~0.6 GB | n/a (tagger) | ~30-100 ms per 128-token window on CPU [est] | vi-only punctuation + casing, F1 period 0.82, comma 0.71, upper 0.89 [V]; CC-BY-SA-4.0 |
| xlm-roberta 47-language punct/truecase (`punctuators`) | small ONNX | <0.5 GB | n/a | fast [V] | **no Vietnamese** in its language list [V] |

Ollama uses llama.cpp; expect within ±30 % of the MLX numbers [B, see `speed-memory.md`]. Vietnamese
tokenizes longer than English: a 60-word vi paragraph is roughly 100-160 tokens [est].

Per-paragraph cost, ~60 words, strict prompt (~250-token system prompt cached by Ollama after the first
call, ~150 tokens in, ~150 out) [est, idle machine]:

| Model | Prefill | Generate | Total warm | Cold load extra |
|---|---|---|---|---|
| gemma3:1b | ~0.3 s | ~2 s | **~2-3 s** | ~1 s |
| qwen3:1.7b | ~0.4 s | ~3 s | **~3-4 s** | ~1-2 s |
| qwen3:4b | ~0.8 s | ~5 s | **~6-7 s** | ~2-3 s |

Expect 1.5-2x worse during a call (GPU shared with video encode/decode, T2 unmeasured) [est]. GPU duty from
polish at ~one paragraph per 30-45 s of speech: ~7-10 % (1.7B) to ~15-20 % (4B) [est], on top of whisper's
20-30 % per speaking track [local, feasibility finding 3].

### 2.3 Punctuation / truecasing restoration models

Useful when the ASR emits no punctuation. Whisper does, so their main use here would be re-punctuating text
joined across chunk boundaries. Only viBERT-capu covers Vietnamese; its handling of English terms inside
vi text is shown only for names and brand casing ("5G MobiFone") [V]. It needs `transformers` + torch
(torch is already in the venv for pyannote). Optional tier, benchmark before adopting.

### 2.4 Whisper prompt conditioning

Whisper follows the *style* of the prompt, not instructions; a short, well-punctuated sample in the target
style nudges punctuation and term spelling, last 224 tokens only, "not especially reliable" [V, OpenAI
cookbook; B, community threads]. The pipeline already prompts with `initial_prompt` + glossary
(`MAX_PROMPT_CHARS` 500). A punctuated bilingual style line costs nothing at runtime, but it changes the
authoritative transcript too (same prompt live and offline; the partial `signature` would change) and
prompt text can leak into output on silence. Treat as a separate ASR experiment, not part of polish.

### 2.5 Two-pass "draft then refined" UIs

- WhisperKit: hypothesis text (~0.45 s) then confirmed text (~1.7 s) [V]; Apple Live Captions /
  SpeechAnalyzer: volatile then finalized results (macOS 26 only, out for now).
- Otter shows near-real-time words; Granola shows no live transcript, only enhances notes after the call [B,
  comparison sites]. Internals of their refinement are not public [gap].
- Common lesson: text the user is reading should change **at most once**, in place, with a subtle cue;
  repeated reflow of the same lines is the main UX failure of streaming correction.

### 2.6 Streaming vs chunk/sentence-level correction

Token-level streaming correction is not possible on top of design A (chunks arrive whole) and is undesirable
anyway: correcting an unfinished sentence lacks right context and causes flicker. Correction per **closed
paragraph** (speaker change or pause) gives the LLM full context, one replacement per paragraph, and bounded
cost.

### 2.7 Guarding against hallucination and meaning drift

From the literature and common practice: (a) gate by ASR confidence, (b) constrain the task (formatting
only, or minimal edits), (c) verify the output deterministically against the input and fall back on
failure, (d) never discard raw text, (e) temperature 0, output length cap.

## 3. Options against the constraints

| Option | Latency after chunk | Extra RAM | Extra GPU | Quality gain | Risk |
|---|---|---|---|---|---|
| R. Deterministic rules | < 10 ms | 0 | 0 | boundary joins, casing, spacing, glossary casing, fillers | near zero |
| P. viBERT-capu re-punctuation | ~0.1-0.3 s CPU [est] | ~0.6 GB | 0 (CPU) | sentence boundaries across chunks (vi) | English terms, CPU contention with call |
| L1. LLM strict (formatting only) | 2-4 s after paragraph close [est] | 1.2-2.0 GB (1-1.7B) | 7-10 % | sentences, punctuation, paragraphs, fillers | RAM pressure, drift (guarded) |
| L2. LLM light (minimal word fixes) | same | same | same | + some ASR word errors | meaning drift, tone "fixes" |
| L3. qwen3:4b | 6-7 s | ~3 GB | 15-20 % | better vi | does not fit alongside a call on this Mac |
| W. Whisper style prompt | 0 | 0 | 0 | small, unreliable | changes authoritative text |

Rejected for live: L3 (RAM), continuous streaming correction (flicker, cost), MLX-LM inside the worker
(would share the whisper process and GPU queue neatly, but adds a second LLM runtime next to Ollama and
reopens AGENTS.md rule 2; revisit only if Ollama RAM is the blocker).

## 4. Proposed design

### 4.1 Tiers

```
 chunk decoded ──> live_segment (raw, unchanged contract) ─────────────────────────> pill: raw text
        │
        └─> Tier 1 rules (same worker loop, < 10 ms) ──> live_polish {tier:"rules"} ──> pill: replaces raw lines
                │
                └─ paragraph closed (speaker change, pause >= 2.5 s, >= 80 words or 45 s)
                       └─> queued; runs only when ASR queue empty + pressure normal + AC power
                            Tier 2 LLM strict (Ollama, small model) ──> guard ──> live_polish {tier:"llm"}
                                                                          └─ fail ──> keep Tier 1 text
```

**Tier 0 (raw):** today's `live_segment`, unchanged. Always stored in `transcript.partial.jsonl`.

**Tier 1 (rules, default when polish is on, < 10 ms):** pure domain function over the paragraph's segments:
NFC; spacing around punctuation; join a chunk that starts lowercase onto a previous same-track segment that
ended without terminal punctuation; capitalize sentence starts; add a final period at paragraph close;
glossary casing (`cfg.glossary` exact spelling); `collapse_repeats` (already shared with `transcribe_blocks`);
optional hiding of pure interjections (vi "ờ", "ừ", "ừm", "à", "ơ"; en "uh", "um"), never discourse
markers ("thì", "kiểu", "nói chung là"). Paragraph boundaries are rule-based here too, so paragraphing never
needs the LLM. Optional Tier 1b: viBERT-capu on vi paragraphs, only if the benchmark shows a gain.

**Tier 2 (LLM strict, opt-in):** one Ollama call per closed paragraph.
- Model default `qwen3:1.7b` (`think: false`), alternative `gemma3:1b`; chosen by the benchmark (section 6).
  Not `qwen3:4b` during recording.
- Prompt: fixed system prompt (cached prefix) + glossary + the previous polished paragraph as read-only
  context + the paragraph. Task: add/fix punctuation, casing, sentence and paragraph breaks, remove listed
  fillers and immediate repetitions; **do not change, add, translate or reorder words**; keep English terms
  as spoken. Plain text out, `temperature 0`, `num_predict` <= 1.5 x input tokens, `num_ctx` 2048,
  `keep_alive` "2m" (unloads during long silences).
- "Light" mode (L2) is a later, separate setting: allows substitutions only where the segment's
  `avg_logprob` is low, each substitution must be near the original (same toneless form for vi, edit
  distance <= 2, or a glossary term). Ship strict first.
- Scheduling: runs in the live job's serial loop between chunks (one heavy job at a time: whisper and the
  LLM never compute at the same time), only when the chunk queue is empty, `memory_pressure` is normal and
  on AC. Otherwise the paragraph stays at Tier 1 (`live_status` reason `polish_skipped`). On pressure rise,
  send a `keep_alive: 0` request to unload the model. At `live_stop`, pending paragraphs are dropped.

### 4.2 Guard (deterministic, in domain)

Compare raw and polished word sequences (NFC, lowercase, punctuation stripped, **diacritics kept**, so a tone
change counts as a substitution):
- strict: zero inserted words, zero substitutions, deletions only from the filler list or immediate repeats;
- any change to digits, glossary terms or language of a span (vi <-> en) fails;
- length ratio 0.8-1.1, no output beyond the paragraph, no markup or commentary;
- fail = keep Tier 1 text and count it (`rejected`). The guard also makes the output reconstructible: a
  passed strict polish is raw words + punctuation/casing/whitespace edits.

### 4.3 Raw text and authority

- `live_segment` and `transcript.partial.jsonl` stay raw; polish writes `.work/transcript.polish.jsonl`
  (`{"v":1,"track","para","seqs":[...],"tier","model","text","edit_rate","ms"}`), deleted at finalize with
  the partials. Stop-time reuse reads only the raw partials, so notes equal the offline path as today.
- The pill shows polished text with a subtle mark and a "raw" toggle; each paragraph is replaced at most
  twice (raw -> rules -> llm) and never after it scrolls out of the visible tail.
- After Stop the live view is replaced by the final transcript as today. A post-Stop "readable transcript"
  (LLM formatting of the final text with the 4B model, no latency limit) is a possible later feature; it
  is out of scope and would stay a separate view, not `transcript.json`.

### 4.4 Contract and settings (additive, rule 5)

- `ready.features` gains `"live_polish"`; stdin `live` gains optional `"polish":"off|rules|llm"` (old worker
  ignores the key); stdout `{"event":"live_polish","job","track","speaker","para","seqs","tier","text"}`
  (old app: `.other`). Swift: `WorkerEvent.livePolish`, `LiveTranscript` keeps a polish map keyed by
  `(track, para)`; both sides in one commit with tests.
- App setting under Recording › Live transcript: "Polish live text" off by default (UserDefaults), with
  "rules only" / "rules + local LLM". Config keys (public API once shipped): `live_polish_model`
  (default `qwen3:1.7b`), `live_polish_pause_sec` (2.5), `live_polish_max_words` (80).
- Layers: rules, paragraphing and guard in `domain/live_polish.py` (pure); scheduling in
  `application/live_transcribe.py` (or a sibling `live_polish.py` to stay <= 300 lines); Ollama call via
  the existing `adapters/outbound/ollama_client.py` (new plain-text method; it is no longer only the summary
  model, so its docstring changes).

### 4.5 Expected latency and RAM

| | Latency (from chunk arrival) | Behind speech | Extra RAM | Extra GPU duty |
|---|---|---|---|---|
| Tier 0 raw | 0 | 10-35 s [local] | 0 | 0 |
| Tier 1 rules | < 10 ms | same | 0 | 0 |
| Tier 1b viBERT | +0.1-0.3 s [est] | same | ~0.6 GB | 0 (CPU) |
| Tier 2 qwen3:1.7b | paragraph close + queue wait + 3-4 s; p95 ~10-20 s under load [est] | ~30-60 s | ~1.7-2.0 GB while loaded | ~7-10 % |
| Tier 2 gemma3:1b | + 2-3 s | ~30-50 s | ~1.1-1.3 GB | ~5-7 % |

Total live footprint with Tier 2: whisper 1.24 GB + worker ~0.5 GB + LLM 1.2-2.0 GB ≈ 3-3.7 GB [est],
next to a video call. On this Mac, with pressure already "warn", Tier 2 will often be skipped by the gate;
that is the intended degradation.

## 5. Vietnamese and code-switching

- **Diacritics and tones:** tone marks distinguish words ("bán"/"bàn"/"bạn"). Strict mode forbids any
  diacritic change; the guard compares with diacritics kept. Small models are weakest in vi, so tone
  "corrections" are the most likely drift.
- **Normalization:** NFC everywhere; old vs new tone placement ("hoà"/"hòa") is display normalization only
  (pick one, apply in Tier 1, fold both in comparisons).
- **Code-switching:** instruct to keep English terms verbatim and never translate; the guard rejects a span
  whose language flips. Glossary casing comes from config, not the LLM.
- **Fillers:** only pure interjections are removable; vi discourse particles carry meaning or politeness.
- **Tokenization:** vi costs ~1.5-2.5x the tokens of en per word [est], so paragraph caps are in words, not
  tokens, and latency is higher for vi.
- **Sentence boundaries:** vi questions often end with particles ("không", "chưa", "à", "nhỉ"); a rule can
  turn a missing final mark into "?" only when the paragraph ends with one of them (benchmark it).

## 6. Metrics and benchmark plan

New `pipeline/bench/live_polish_bench.py`, reusing `live_chunks.py` (replay into live partials),
`live_corpus.py`, `live_eval.py` and `domain/metrics.py`. One model at a time, `nice 10`, only at normal
memory pressure, no runs during calls except T2.

Corpora: `asr_bench` synthetic `syn` / `synfast` (references have punctuation, but TTS has no
disfluencies), plus the planned three real >= 10 min meetings with corrected references (vi-heavy, en,
code-switched; see `realtime-feasibility.md` section 8). Add ~30 hand-written spontaneous vi/en paragraphs
with fillers, false starts and tone errors as a text-only set (no audio needed: polish is text in, text out).

Systems: raw, rules, rules + viBERT, rules + `gemma3:1b`, rules + `qwen3:1.7b`, rules + `qwen3:4b`
(reference only), strict vs light prompts.

| Metric | Definition | Target (strict) |
|---|---|---|
| WER vs reference | `metrics.wer`, punctuation stripped, diacritics kept; polished minus raw | <= +0.2 pp (strict should be ~0) |
| Punctuation / sentence-boundary F1 | per mark (. , ?) and boundary vs reference punctuation | boundary F1 >= raw + 0.10 |
| Casing accuracy | sentence starts + glossary terms | >= 0.95 |
| Edit rate | word edits(raw, polished) / raw words | strict ~ filler share only |
| Hallucination rate | inserted content words, changed numbers, dropped/altered glossary terms, language flips, per 1000 words, before and after guard | 0 after guard; report pre-guard |
| Guard rejection rate | rejected paragraphs / paragraphs | < 10 % (else prompt/model unsuitable) |
| Meaning drift | blind human yes/no "same meaning" on 30 paragraphs per language mix | >= 97 % yes |
| Latency | paragraph close -> `live_polish`, split into queue wait / prefill / decode, p50 / p95; tok/s | p50 <= 5 s, p95 <= 15 s idle |
| Resources | Ollama RSS (`/api/ps`), pressure transitions, swap delta, GPU duty (`powermetrics`) | +<= 2 GB; no normal -> warn transition caused by polish |

Order: (1) rules vs raw on synthetic + text-only set (no model, cheap, may already deliver most of the
value); (2) tiny latency/RAM probe of `gemma3:1b` and `qwen3:1.7b` on 3 paragraphs when pressure is normal;
(3) full strict comparison; (4) T2 during a real call with Tier 2 on; (5) light mode only if strict leaves
visible ASR errors users care about.

## 7. Risks and open questions

- **RAM** is the main risk: an extra 1.2-2 GB next to whisper and a call on a machine already at "warn".
  Mitigation: pressure gate, `keep_alive` unload, rules-only fallback. If Tier 2 is skipped most of the time,
  it is not worth shipping; measure skip rate in T2.
- **Meaning drift** from small models on vi; mitigated by strict mode + guard, but the guard cannot catch a
  harmful punctuation change (e.g. a moved comma or question mark changing intent). Measured by the human
  drift check.
- **User confusion** between polished live text and the final transcript (different wording at chunk
  boundaries); mitigated by the "raw" toggle and replacing the live view at Stop.
- **Value cap:** live text is 10-35 s late before any polish; Tier 2 adds ~5-30 s more. If the use case is
  glance-back/search, Tier 1 may be enough.
- Open: does Whisper turbo's own punctuation on vi need help at all (measure raw punctuation F1 first)? Is
  viBERT-capu safe with English terms? Do `qwen3:1.7b` / `gemma3:1b` follow "do not change words" in vi?
  Does Ollama's GPU use stutter the call more than whisper alone (T2)?

## 8. Sources (accessed 2026-10-23)

- HyPoradise https://arxiv.org/pdf/2309.15701 ; Whispering LLaMA https://arxiv.org/pdf/2310.06434
- Compact phrasal rewrites for ASR post-editing https://arxiv.org/pdf/2501.13831
- ASR error correction with LLMs, confidence filtering https://fugumt.com/fugumt/paper_check/2409.09554v1_enmode
- Clarispeech https://airi.net/articles/clarispeech-llm-enhanced-speech-recognition-post-correction
- Hindi post-ASR correction, EACL 2026 https://preview.aclanthology.org/ingest-eacl/2026.eacl-short.45.pdf
- Diacritics: https://arxiv.org/pdf/2410.24140 ; PiDA https://arxiv.org/pdf/2606.12911 ; Vietnamese
  capitalization and punctuation recovery https://arxiv.org/pdf/2207.01312
- viBERT-capu https://huggingface.co/dragonSwing/vibert-capu ; VFastPunct https://pypi.org/project/VFastPunct/2.0.1
- xlm-roberta punctuation 47 languages https://huggingface.co/1-800-BAD-CODE/xlm-roberta_punctuation_fullstop_truecase
- Qwen3-4B on M1 Pro (oMLX community) https://omlx.ai/benchmarks/1lwlfozk ; Qwen3 1.7B estimates
  https://willitrunai.com/can-run/qwen-3-1.7b-on-m1-pro-16gb ; Gemma 3 1B https://canirun.ai/model/gemma3-1b/
- Whisper prompting guide (OpenAI cookbook mirror) https://gwern.net/doc/www/cookbook.openai.com/0735557bf27103c12647d313cf3a37a6ea4a25fc.html ;
  https://spokenly.app/docs/whisper-prompting
- Granola vs Otter https://www.usecarly.com/blog/granola-vs-otter/
- WhisperKit https://arxiv.org/html/2507.10860v1 (via `realtime.md`)
