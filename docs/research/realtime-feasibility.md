# Live transcription, design A: offline feasibility (T3, T4)

Date: 2026-10-21. Status: **provisional**. Tests T3 (chunk boundaries) and T4 (Stop-time reuse) of
[`realtime.md`](realtime.md) section 5, replayed offline on this Mac (M1 Pro, 16 GB, macOS 15.5). Nothing of
design A is built; the bench code is `pipeline/bench/live_*.py`. T1, T2 and T5 were not run.

## 1. Verdict

**Design A as written in 4.1 does not pass T3/T4. Do not start building it yet; a narrowed A is worth building.**

- On paced speech (1 s between utterances) per-chunk decoding is as good as the offline path: WER +0.3 pp
  against the known text, term recall 13/13, language 100 %, no forced cuts.
- With fast turn-taking (0.3 s gaps, below the 0.7 s pause) it fails every T3 criterion except latency: WER +10.2 pp,
  language agreement 81 %, 29 % forced cuts, a lost glossary term. The 4.1 ambiguity rule (minority speaker > 30 % of a
  segment) never fires there, so the damage reaches the final transcript (+10.3 pp vs the known text).
- A stricter reuse rule (re-decode chunks that were force-cut or span a second speaker for >= 1 s) restores
  quality (synfast: 7.1 % vs 7.5 % offline, i.e. -0.3 pp) but re-decodes 65 % of that corpus.
- Post-Stop time for a 1 h meeting is 59 % of today (72 % with the strict rule), not <= 50 %, because diarization
  (50 % of today) is untouched. Reaching 50 % needs diarization <= 731 s instead of 899 s.
- **The real corpus is far too small to confirm or refute anything** (section 3). Re-run on three real meetings of
  >= 10 min before building (section 8).

## 2. Setup

- Model `mlx-community/whisper-large-v3-turbo-q4` (config default, cached locally, `HF_HUB_OFFLINE=1`), languages
  vi/en, `whisper_vad` on, glossary empty for real meetings (the user's config) and the `asr_bench` glossary for
  the synthetic corpora. One process, one model, one corpus at a time, `nice 10` + utility QoS (`low_priority()`).
- Memory: `kern.memorystatus_vm_pressure_level` was 2 (warn) at the start of every heavy run. The first run waited
  8 min for normal pressure, then proceeded with `--allow-warn` (scope is ~1.2 GB and ~3 min of decode per run).
  Swap use was 16.5-20 GB (swap file 17-21.5 GB) throughout, so absolute wall times may be inflated; ratios are
  more reliable.
- **Reference = the offline pipeline, not humans.** `offline_reference` re-runs `stage_transcribe` (diarization
  turns -> `build_blocks` -> `split_long_blocks(28 s)` -> `transcribe_blocks`) with the same model. "WER" below is
  disagreement with that transcript (NFC, lowercase, no punctuation, `metrics.words`; CER on the same text). It is an
  upper bound on the quality delta only if offline is right; both can be wrong.
- Live replay (`live_chunks.py`): each track is fed as a stream, polled every 1 s. Policy of 4.1: min 4 s, max 28 s,
  pause >= 0.7 s (cut midway into the pause, not before min), forced cut at the quietest 0.3 s of the last 40 % at
  28 s, pad 0.25 s, `frame_db`/`speech_threshold_db` on the audio seen so far (refreshed every poll up to 30 s, then
  every 30 s; no cut before 8 s of audio, a warm-up the design text lacks). Each chunk is decoded with
  `transcribe_blocks` itself (VAD, vi/en choice, glossary prompt, filters), given only audio that had arrived. A
  remainder at Stop is a tail chunk (decoded for T3, not reusable in T4).
- Comparison is gated: live segments must lie >= 50 % inside a same-track diarization turn, because the offline
  path never decodes outside turns (this also implements the mic bleed rule, since resolved mic turns exclude
  remote speech). Ungated ("raw") numbers are in the JSON.
- T4 (`live_merge.py`, prototype of `partial_merge.py`): speaker = diarization speaker with max overlap; segment
  dropped if < 50 % covered by turns; ambiguous if minority speakers > 30 % of the segment (re-decoded);
  uncovered = turn time outside decoded chunks (tail) + ambiguous spans. Uncovered turn pieces go through
  `build_blocks` -> `transcribe_blocks`. Variant `strict` also re-decodes whole chunks that were force-cut or
  contain >= 1 s of a second speaker.
- Post-Stop time: learned per-stage factors (`~/.cache/meeting-notes/timings.json`, EMA of real runs) for a 1 h
  meeting; only the transcribe stage shrinks, by the re-decoded share of speech, plus one p90 chunk decode.

## 3. Corpus

Requested: three meetings, 10 min excerpts (vi-heavy, en, code-switched). Available: four short test recordings in
`~/MeetingNotes` (40 s to 4.9 min, 8.9 min in total, 45 s of diarized speech). No recording reaches 10 min, so each
is used whole. No audio, transcript or text is stored in the repo; results are in a scratch dir outside it.

| Id | Source | Audio | Tracks | Diarized speech | Offline words | Content |
|---|---|---|---|---|---|---|
| m1 | real, 2026-10-19 | 291 s | mic + system | 7 s | 9 | en/vi test phrases, long ambient/other audio |
| m2 | real, 2026-10-19 | 101 s | mic only | 17 s | 25 | vi/en code-switch, ambient audio |
| m3 | real, 2026-10-20 | 40 s | mic + system | 20 s | 75 | vi; mic hears the speakers (bleed corr 0.55) |
| syn | `asr_bench` TTS | 194 s | 1 track, 3 speakers | 106 s | 327 | vi / en / code-switch, 1 s gaps, known text |
| synfast | same, 0.3 s gaps | 163 s | 1 track, 3 speakers | 106 s | 328 | stress: quick turn-taking, known text |

The fifth recording (1 s of speech) was skipped. Synthetic corpora are supplementary: clean single-voice TTS, and
their "diarization" is the ground-truth turn list (perfect). The real corpus has 109 reference words in total.

## 4. T3 results (policy 4.1)

WER/CER = live (gated) vs offline, in %. dTruth = WER(live) - WER(offline) against the known text (synthetic only),
pp. Recall = share of offline speech seconds that has a live segment. Wall = decode time per speech chunk,
RTF = wall / chunk seconds. Duty = total decode wall / chunk audio.

| Id | Words | WER | CER | dTruth | Recall % | Speech chunks | Forced | Lang agree % | Terms | Wall med s | RTF med / p90 | RTF > 1 | Duty |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| m1 | 9 | 44.4 | 26.8 | n/a | 100 | 24 | 3/24 | 100 | n/a | 4.23 | 0.43 / 1.30 | 4 | 0.49 |
| m2 | 25 | 100.0 | 80.8 | n/a | 53 | 3 | 1/3 | 100 | n/a | 4.96 | 0.88 / 1.18 | 1 | 0.42 |
| m3 | 75 | 2.7 | 2.2 | n/a | 93 | 5 | 0/3 | 100 | n/a | 1.49 | 0.28 / 0.37 | 0 | 0.20 |
| syn | 327 | 3.4 | 1.4 | +0.3 | 97 | 21 | 0/21 | 100 | 13/13 | 1.42 | 0.26 / 0.33 | 0 | 0.21 |
| synfast | 328 | 15.2 | 14.4 | +10.2 | 87 | 7 | 2/7 | 81 | 10/12 | 1.54 | 0.08 / 0.13 | 0 | 0.08 |

Forced = forced cuts / policy cuts among decoded (speech) chunks. Pooled: 6/58 = 10.3 % forced among decoded
chunks, 6/192 = 3.1 % among all chunks (silent ones included); language agreement 92.0 % over 221 s.

Exploratory variant, shorter chunks (min 2 s, pause 0.35 s; m1 not run):

| Id | WER | dTruth | Recall % | Forced | Lang agree % | Terms | Duty |
|---|---|---|---|---|---|---|---|
| m2 | 100.0 | n/a | 64 | 0/5 | 100 | n/a | 1.53 |
| m3 | 8.0 | n/a | 83 | 0/8 | 100 | n/a | 0.43 |
| syn | 2.4 | +0.9 | 95 | 0/25 | 100 | 13/13 | 0.29 |
| synfast | 9.5 | +5.6 | 97 | 0/20 | 95 | 12/12 | 0.25 |

### Pass criteria (section 5)

| Criterion | Measured | Result |
|---|---|---|
| WER delta <= 1 pp | syn +0.3 pp; synfast +10.2 pp; short-chunk variant +0.9 / +5.6 pp. Real meetings: no reference; live-vs-offline disagreement 2.7 % on m3 (75 words), 44-100 % on m1/m2 (9-25 words, ambient audio). | **Fail** (fast turn-taking); pass on paced speech; real inconclusive |
| Term recall drop <= 0.05 | syn 13/13; synfast 10/12 (-0.17); no glossary terms in the real meetings | **Fail** on synfast; untestable on real |
| Forced cuts < 5 % of chunks | 10.3 % of decoded chunks (syn 0, synfast 29 %, real 13 %); 3.1 % of all chunks | **Fail** on decoded chunks (silence dilutes the other denominator) |
| Language agreement >= 95 % of speech seconds | pooled 92.0 % (syn 100, real 100 over 25 s, synfast 81); short-chunk variant 97.8 % | **Fail** (baseline policy) |

## 5. T4 results

| Id | Rule | Kept / ambiguous / dropped | Speaker agree % | Misattributed s | Re-decoded speech (excl. tail) | WER vs offline | vs truth (offline -> final) |
|---|---|---|---|---|---|---|---|
| m1 | spec | 3 / 0 / 29 | 100 | 0 | 0 % | 44.4 | n/a |
| m2 | spec | 2 / 0 / 1 | 100 | 0 | 0 % | 100.0 | n/a |
| m3 | spec | 4 / 0 / 1 | 100 | 0 | 0 % (system tail 29 % of 12.8 s) | 2.7 | n/a |
| syn | spec | 21 / 0 / 0 | 100 | 0 | 0 % | 3.4 | 6.5 -> 6.8 % |
| synfast | spec | 13 / 0 / 0 | 97.3 | 2.7 | 0 % | 15.2 | 7.5 -> 17.7 % |
| synfast | strict | 6 / 7 / 0 | 100 | 0 | 65.5 % (69.5 s) | 0.3 | 7.5 -> 7.1 % |
| m2 | strict | 1 / 1 / 1 | 100 | 0 | 47.9 % | 100.0 | n/a |

`strict` equals `spec` on m1, m3 and syn. "Dropped" = outside diarization turns (m1: 29 ambient
segments decoded live and discarded; m3: mic bleed). The `spec` rule flagged no ambiguous segment in any corpus.

System speech re-decoded: spec 1.6 % pooled (all of it m3's 3.7 s tail of a 40 s clip, 0.07 % without tail);
strict 32.7 % of synthetic system speech (syn 0 %, synfast 65 %).

Post-Stop wall time, 1 h meeting (learned stage factors; today = 1792 s = 29.9 min: prepare 54, diarize 899,
transcribe 733, summarize 105 s):

| Scenario | Spec rule | Strict rule |
|---|---|---|
| A, pyannote as today | 1064 s (59 %) | 1286 s (72 %) |
| A, diarization 2x faster | 615 s (34 %) | 836 s (47 %) |
| A, diarization 5x faster | 345 s (19 %) | 566 s (32 %) |
| Largest diarization time for <= 50 % | 731 s | 510 s |

Strict-rule numbers use a 30 % re-decode share pooled over all corpora (dominated by synfast); real pacing will
differ.

### Pass criteria

| Criterion | Measured | Result |
|---|---|---|
| Ambiguous (re-decoded) system speech < 15 % | spec 0 % (1.6 % with a 40 s-clip tail); strict 33 % synthetic | **Pass as specified**, but the rule under-detects (below) |
| Final WER within 0.5 pp of no-reuse | vs offline: spec 3.4 pp (syn), 15.2 pp (synfast), 2.7 pp (m3); strict synfast 0.3 pp, syn 3.4 pp. vs truth: spec syn +0.3 pp, synfast +10.3 pp; strict synfast -0.3 pp | **Fail** (spec rule, fast turn-taking); pass vs truth with strict |
| Post-Stop 1 h <= 50 % of today | 59 % (spec), 72 % (strict) with today's diarization | **Fail** |

## 6. Findings

1. **Whisper fixes one language per call.** Offline `split_by_language` splits a multi-turn block by language;
   a live chunk of up to 28 s cannot. On m2 an English utterance inside a Vietnamese chunk was lost (recall 53 %); on
   synfast English sentences were labelled `vi` (81 % agreement) and spans were dropped at a forced cut.
2. **The 4.1 ambiguity rule is too weak.** Whisper segments rarely span two speakers, but chunks do: a minority of
   12 % of a long segment is below 30 %, yet the chunk's language, boundaries and speaker labels are wrong.
3. **Decode cost has a fixed floor of about 1.4-1.6 s per call** (the 30 s encoder window plus language detection),
   independent of chunk length: median RTF 0.26-0.28 at 5 s chunks, 0.08 at 20 s chunks. Live decode wall equals
   the offline decode wall on paced speech (syn: 30.3 s vs 28.6 s), but shorter chunks raise the duty
   (0.21 -> 0.29), against the 15-20 % estimate in 3A. Two tracks speaking at once would roughly add up (estimate).
4. **Ambient audio is expensive.** m1 (291 s, 2 diarized utterances) produced 24 speech chunks, 92 s of decode,
   RTF > 1 on 4 chunks (temperature fallback) and 29 segments that the merge discarded. The live path needs a
   gate before decoding (minimum voiced seconds, skip mic chunks under bleed as 4.5 proposes).
5. **Mic bleed is real** (m3): the mic chunk contained the remote speech; gating by resolved mic turns removed it,
   but only after the decode was paid.
6. The speech-threshold estimate degenerates on short prefixes (a flat signal makes every frame "quiet"); a warm-up
   of several seconds is required. Not mentioned in 4.1.
7. Reuse cannot match the offline text exactly even without boundary errors (numerals, context effects: syn 3.4 %
   disagreement with +0.3 pp against the truth), so "within 0.5 pp of the no-reuse run" is unattainable as a
   disagreement metric; judge against the known text or a human reference.

## 7. Caveats

- Real data: 9 reference words on m1, 25 on m2, 75 on m3, no human transcripts, no >= 10 min recording, and
  m1/m2 are test sessions with ambient/other audio. Treat real-corpus rows as smoke tests, not statistics.
- Synthetic corpora: one TTS voice per language, perfect diarization, `synfast` is an artificial stress (every
  gap 0.3 s). One run per configuration; Whisper at temperature 0 is near-deterministic, but variance is unmeasured.
- Replay assumptions: sequential decode, no GPU contention (that is T2), no backlog/skip/defer (all chunks
  processed), per-track language prior inactive (every chunk >= 4 s is "long" in `transcribe_blocks`), 1 s polls.
- Mic bleed and speaker merge were exercised only on m3 (one remote speaker); multi-speaker system audio only on
  synthetic data.
- Timing model: stage factors are EMAs from 40-290 s meetings (diarize 0.249 s/s, transcribe 0.203 s/s, summarize
  0.026 s/s + 12 s); a 1 h value is an extrapolation, and the summary of a 1 h transcript likely costs more than 105 s,
  which would push the ratio toward 1.
- Pressure was "warn" with heavy swap during all runs; absolute wall times may be inflated, and no repeat runs
  were made.

## 8. Recommendation for design A

1. **Do not build A as specified.** Amend 4.1 first: (a) re-decode chunks that are force-cut or span a second
   diarization speaker for >= 1 s (the `strict` rule), not just ambiguous segments; (b) gate decoding on voiced
   speech and skip mic chunks under bleed; (c) add a warm-up before the first cut. Expect to keep reuse high on
   mic-only and slow-paced calls, and low on lively multi-speaker system audio.
2. **Re-run T3/T4 on three real meetings of >= 10 min** (vi-heavy, en, code-switched; with a corrected or human
   reference) before committing. The synthetic result shows the mechanism, not the real-world rate.
3. **Shorter chunks are not a fix**: min 2 s / pause 0.35 s helps language agreement (97.8 %) and forced cuts
   (0 %) but leaves +5.6 pp on synfast and raises GPU duty.
4. **Value is capped by diarization**: with today's pyannote, A saves at most 41 % of post-Stop time. Pair A with a
   faster diarizer (2x gives 34 % of today, 47 % with the strict rule) or run T2 and the diarization work first.
5. T2 (load during a real call) stays the gate; budget at least 20-30 % GPU duty per speaking track.

## 9. Reproduce

```bash
cd pipeline   # one model at a time; check `memory_pressure` first
B=~/MeetingNotes; S=/path/to/scratch   # outside the meeting folders
uv run python bench/live_chunk_bench.py $S --meeting "$B/<folder>=m1" ... --synthetic --synthetic-fast   # T3
uv run python bench/live_chunk_bench.py $S ... --min-sec 2 --pause-sec 0.35 --tag short                  # variant
uv run python bench/live_reuse_bench.py $S --meeting "$B/<folder>=m1" ... --synthetic --synthetic-fast   # T4
```

Files: `live_corpus.py` (corpora, offline reference), `live_chunks.py` (policy, replay, chunk decode),
`live_merge.py` (`merge_partials`), `live_eval.py` (metrics), `live_chunk_bench.py` (T3), `live_reuse_bench.py` (T4);
unit tests in `pipeline/tests/unit/bench/`.

## 10. Shipped code check (2026-10-21)

Design A was built with the section 8 amendments (strict rule, voiced/bleed gate, warm-up). Smoke check of the
product path on a copy of m3 (40 s, two tracks; one run, memory pressure "warn", on battery, so the replay used
`live_on_battery` and tolerated "warn" through a scratch probe; the shipped defaults would have skipped/deferred every
chunk): `meeting-notes live --simulate 4` decoded 2 chunks (10 gated as silent, RTF 0.78 with model load), then
`process` reused 13.3 s of diarized speech and decoded 7.0 s (tail) after Stop. Transcribe stage 4.2 s vs 8.0 s for a
fresh offline run; final text 2 of 75 words different from that run (2.7 %, at the live/tail boundary), same speakers.
Still no >= 10 min corpus and no T2 (load during a call).

## 11. Design B: live captions with WhisperKit (2026-10-23)

Design B is built as an add-on to A (`MeetingNotesCaptions` helper, Settings › Advanced › Live transcript = Fast
captions). Bench: `pipeline/bench/caption_bench.py` streams the `asr_bench` synthetic corpus (`syn`, 194 s, 20
utterances, vi / en / code-switch, `say` voices, known text; never a real recording) into the helper at 1x real time
through the app's own wire protocol (100 ms `audio` lines), one track. WhisperKit 1.1.1, models from
`argmaxinc/whisperkit-coreml` @ `0f63a78` (ungated: downloaded with no token in the environment), encoder and decoder
on the Neural Engine (`cpuAndNeuralEngine`), mel on CPU. M1 Pro, 16 GB, macOS 15.5, memory pressure "warn"
throughout, one run per model, no call running (T2 still open).

Metrics: TTFC = speech onset -> first caption text overlapping the utterance; lag = caption arrival - end of the audio
it covers (every hypothesis/final); final = utterance end -> confirmed text; WER/CER of the confirmed captions vs the
known text (`metrics.wer`, NFC, lowercase, no punctuation). Footprint = `footprint -p` of the helper, sampled every
second; Core ML weights resident on the Neural Engine side are not attributed to the process (not measurable without
root; at most the weight size, below).

| Model (download) | Load s (warm) | TTFC p50 / p95 s | Lag p50 / p95 s | Final p50 / p95 s | WER % | CER % | Footprint peak MB |
|---|---|---|---|---|---|---|---|
| tiny (77 MB) | 0.7 | 0.68 / 1.32 | 0.11 / 1.74 | 0.57 / 5.43 | 48 | 31 | 72 |
| base (147 MB) | 0.7 | 1.06 / 3.44 | 0.20 / 4.97 | 0.94 / 5.94 | 48 | 29 | 75 |
| **small (486 MB)** | 1.0 | **1.33 / 1.73** | **0.50 / 2.11** | **0.67 / 3.24** | **30** | **15** | **97** |
| small_216MB (palettized) | 1.2 | 1.56 / 5.84 | 0.81 / 7.99 | 2.40 / 10.37 | 49 | 35 | 120 |
| large-v3-turbo_632MB | 3.1 | 1.99 / 5.12 | 1.11 / 5.80 | 2.18 / 10.43 | 20 | 14 | 102 |
| A: turbo q4 MLX (section 4, same corpus) | n/a | 10-35 s behind speech | | | 6.8 (offline 6.5) | | 1240 (MLX peak) |

First load per account compiles the model for the Neural Engine: 18-50 s for tiny-small, ~14 min for turbo (one
time, done by `--prepare`).

Decision: **`openai_whisper-small`** is the default. It is the only model that meets the <= 2 s budget at p95 (TTFC
1.73 s) with usable text (CER 15 %); turbo has the best text but p95 above 5 s (its 32-layer encoder runs on every
update), the palettized small is both worse and slower on this ANE, tiny/base are fast but about half the words are
wrong in Vietnamese. B's text is a draft: WER 30 % vs A's 6.8 % on the same corpus, which is why A stays
authoritative and replaces captions as its chunks land; B is never written to any file.

Apple `SFSpeechRecognizer` (checked on this Mac): `vi-VN` is in `supportedLocales` but
`supportsOnDeviceRecognition` is false (server only; "No Assistant asset for language vi-VN"), so it is ruled out by
the local-only rule. `en-US` is on-device.

Open: T2 (load during a real call, ANE shared with Zoom/Meet effects), two tracks speaking at once (the helper decodes
one window at a time, most-behind track first), real meetings >= 10 min.
