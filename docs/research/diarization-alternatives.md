# Ungated diarization alternatives

Date: 2026-10-23. Scope: replace or supplement the gated pyannote pipelines used by `pipeline/` (`settings.py`: `pyannote/speaker-diarization-community-1`, then `3.1`; embedding fallback `pyannote/wespeaker-voxceleb-resnet34-LM`; `pyannote-audio>=4.0.7`). Companion to section 3 of `one-click-install.md`. Research only; nothing installed or run.

Legend: **[self]** = reported by the model authors; **[indep]** = third-party run; **[unverified]** = not checked against a primary source.

## 1. Baseline (pyannote)

Official model card, no collar, overlap scored [self] (https://huggingface.co/pyannote/speaker-diarization-community-1):

| Dataset | 3.1 | community-1 |
|---|---|---|
| AMI IHM / SDM | 18.8 / 22.7 | 17.0 / 19.9 |
| AliMeeting ch1 | 24.5 | 20.3 |
| AISHELL-4 | 12.2 | 11.7 |
| DIHARD3 full | 21.4 | 20.2 |
| VoxConverse 0.3 | 11.2 | 11.2 |
| CALLHOME p2 | 28.5 | 26.7 |

community-1: CC-BY-4.0, gated `auto` (click-through form). Verified by HF API today: the weights are the same as the unofficial mirror `pyannote-community/speaker-diarization-community-1` (ungated, CC-BY-4.0; sha256 match was checked in `one-click-install.md`). 3.1 and segmentation-3.0 are MIT, gated.

**Key point:** the gate is lead capture, not a license term. CC-BY-4.0 and MIT allow redistribution. The zero-quality-loss "alternative" is to bundle community-1 (34 MB) in the app and load it from a local dir (already the recommendation in `one-click-install.md`). Everything below is for the case where we want a different engine.

## 2. Comparison

HF gating verified today via `huggingface.co/api/models/<id>` (`gated` field).

| Candidate | Gated | License (commercial?) | DER (no collar unless noted) | Size | Apple Silicon runtime | Max spk / overlap | Language-indep. | Python effort |
|---|---|---|---|---|---|---|---|---|
| **pyannote community-1 bundled / mirror** (reference) | official yes, mirror no | CC-BY-4.0, yes + attribution | table above [self] | 34 MB | torch MPS ~20-25x RT, CPU ~1.5-2x RT [indep: FluidAudio benchmarks doc] | unlimited, overlap yes | Yes (acoustic) | 0.5 day (local dir) |
| **FluidAudio** offline = community-1 ported to CoreML (Swift SDK, CLI) | no (`FluidInference/speaker-diarization-coreml`) | SDK Apache-2.0; models "scoped CC-BY-4.0" (see NOTICE.md) | AMI SDM 16 meetings avg 10.6 [self, M5 Pro]; VoxConverse 15.07 (step 0.2) / 13.89 (step 0.1) [self] vs ~11 for torch; fp16 loses a little | ~129 MB | ANE; RTFx 323 (AMI), 122 (VoxConverse) [self] | as community-1, overlap yes | Yes | Swift only; Python via CLI subprocess or Senko. 1-2 weeks to integrate in app |
| **Senko** (3D-Speaker pipeline: pyannote seg-3.0 VAD + CAM++ + spectral/UMAP-HDBSCAN; CoreML on Mac) | no | MIT code; model licenses not stated in README [unverified]; seg-3.0 MIT, CAM++ Apache-2.0 repo | VoxConverse 13.5, AISHELL-4 13.3, AMI-IHM 26.5 [self] | ~tens of MB | Fast: 1 h audio in ~7.7 s on M3 [self] | clustering-based, no real overlap handling | Yes (Mandarin-trained CAM++ but acoustic) | `pip`, `senko.Diarizer().diarize(wav)`; 1-2 days |
| **sherpa-onnx offline diarization** (pyannote seg-3.0 ONNX 7.0 MB + 3D-Speaker/NeMo/WeSpeaker ONNX embeddings, fast clustering) | no (GitHub release assets, curl returns 302, listing verified) | Code Apache-2.0 (verified LICENSE); seg-3.0 MIT, embeddings per their repos | No published DER vs pyannote found. Same seg model + simpler clustering (no VBx/PLDA) so expect between fallback and 3.1; 3D-Speaker recipe on same family: AMI SDM 21.76, AliMeeting 19.73, AISHELL-4 10.30, VoxConverse 11.75 [self, github.com/modelscope/3D-Speaker] | ~7 MB + 7-30 MB embedding | onnxruntime CPU (CoreML EP optional); fast | speaker count by threshold or fixed N; overlap not modeled | Yes | `pip install sherpa-onnx`, no torch; 2-4 days |
| **3D-Speaker** pipeline (CAM++/ERes2Net, ModelScope) | ModelScope, no login for download [unverified] | Apache-2.0 code | see sherpa row (same recipe) | CAM++ 7.2 M params | torch CPU/MPS | optional overlap detector needs HF token (pyannote) | Yes | ModelScope dependency; Senko/sherpa are better wrappers |
| **DiariZen** (BUT, WavLM-Large pruned + Conformer, EEND-VC with pyannote-style clustering) | no | Code MIT, **weights CC-BY-NC-4.0: not commercial** | AMI-SDM 13.9, AliMeeting far 10.8, AISHELL-4 10.1, DIHARD3 14.5, VoxConverse 9.1, MSDWild 15.8, RAMC 11.0 (s80-v2) vs pyannote 3.1 22.4 / 24.4 / 12.2 / 21.7 / 11.3 / 25.3 / 22.2 [self, github.com/BUTSpeechFIT/DiariZen]. Independent: 13.3 on a 196.6 h multilingual set vs 11.2 for pyannoteAI commercial [indep, via search summary, unverified] | 63.3 M params (pruned) | torch only, repo pins torch 2.1.1 + CUDA 12.1 + forked pyannote; MPS/CPU untested. Heavy on 16 GB with Whisper | no stated cap (EEND-VC); overlap yes | Yes; trained on multilingual meeting data incl. Mandarin | High: conda 3.10, git submodules, pinned torch conflicts with `pyannote-audio>=4`; 1-2 weeks |
| **NVIDIA Nemotron-3-Diarization** (streaming Sortformer v3) | no | OpenMDW-1.1, commercial OK (HF card + API) | AMI MHM 9.25 / SDM 11.14, DIHARD3 12.73, CALLHOME p2 9.10 (30.4 s latency) [self; AMI forced-alignment refs, not comparable to pyannote refs] | ~100 M params | Targets NVIDIA GPU/Linux (NeMo 3.0, Python >= 3.12; C++ runtime). No CoreML port found | 8 speakers; overlap yes | English-centric training [unverified] | NeMo on Mac: poor. Not practical |
| **NVIDIA Sortformer 4spk v2.1** | no | NVIDIA Open Model License (v1 was CC-BY-NC) | AMI IHM 15.9 / SDM 17.8, DIHARD3 19.5, CALLHOME 10.1 [self]. FluidAudio CoreML run: AMI SDM 31.7 streaming, 56.7 whole-file offline [self, CoreML port, worse] | 117 M params | NeMo; CoreML via FluidAudio (weak) | **4 speakers max**, degrades at 5+ | English-centric | Not recommended |
| **FluidAudio LS-EEND** (CoreML) | no | MIT (HF tag) | AMI dev 20.97 / eval 20.76 [self, upstream LS-EEND]; AMI SDM 20.7 [self] | small | CPU/ANE, RTFx ~75 | 10 speakers, online | Yes | Swift only |
| Rev reverb-diarization v1/v2 | **yes** | "other" (Rev non-commercial) | WDER only, -16.5% rel. vs pyannote 3.0 [self] | 11 MB / 254 MB (sherpa export) | onnx | - | - | Rejected |
| Picovoice Falcon | AccessKey (account) | Proprietary, free tier limited | Vendor-reported only | small | CPU | - | - | Rejected (also gated) |
| pyannote 3.1 + seg-3.0 mirror | mirror ungated | MIT | 3.1 column above | 6 MB + 27 MB | torch | unlimited | Yes | 0.5 day; superseded by community-1 mirror |

Notes on numbers: collars, overlap scoring and reference labels differ across sources. Only within-table rows from the same source (pyannote card, DiariZen README) are directly comparable. The soniqo.audio head-to-head (https://soniqo.audio/benchmarks/diarization) is a vendor-run [indep-ish] comparison with a 0.25 s collar: English conversation Sortformer streaming 13.81 vs community-1 15.22; community-1 much worse on Spanish/Russian/Azerbaijani synthetic sets, i.e. language-dependent behaviour exists even for "acoustic" models, so test on Vietnamese.

## 3. Findings

1. **Quality leaders are not usable for us.** DiariZen has the best published open DER (roughly 20-45% relative better than 3.1 on AMI, AliMeeting, DIHARD) but its weights are CC-BY-NC-4.0 and the stack is CUDA-pinned. Nemotron-3 reports the lowest numbers overall and is commercially licensed, but needs NeMo/NVIDIA. Neither fits an M1 Pro app.
2. **Same quality, no gate:** bundle community-1 (CC-BY-4.0) or use the CoreML port in FluidAudio. FluidAudio claims AMI SDM 10.6 (self) and ~120-320x realtime on ANE; the Swift-only SDK conflicts with the Python pipeline, but its CLI can be shelled out to.
3. **Python-native, light, ungated:** sherpa-onnx and Senko. Both reuse pyannote segmentation-3.0 (MIT, 7 MB ONNX/CoreML) with 3D-Speaker/CAM++ embeddings and simple clustering. Expect VoxConverse ~11.8-13.5 and AMI worse than pyannote (AMI-IHM 26.5 for Senko vs 17.0 community-1; AMI SDM 21.8 for 3D-Speaker vs 19.9). Weak spots: speaker counting and overlap. Their upside is dropping torch (574 MB) and speed.
4. **No evidence on Vietnamese for any of these.** All are speaker-embedding or EEND models trained mostly on English/Mandarin; Vietnamese is tonal but speaker traits are acoustic, so degradation is expected to be modest, but must be measured.

## 4. Recommendation

1. **Default (do now):** community-1 bundled as a local dir with CC-BY attribution (or mirrored under our own account), no token. Zero quality change. Keep the existing wespeaker clustering as last fallback.
2. **Fallback candidate to evaluate:** sherpa-onnx (or Senko) as an ungated, torch-free second tier replacing the current agglomerative fallback. Likely better than the present fallback at near-zero download cost. **Measured 2026-10-23 (section 7): built as opt-in; slower than pyannote on MPS and over-splits speakers on 60 min, so neither default nor fallback yet.**
3. **Watch/optional:** FluidAudio CLI as an opt-in fast path (ANE, community-1 weights) if diarization time on M1 Pro matters. **Measured 2026-10-23 (section 8): built as opt-in (`diarization_engine = "fluidaudio"`); DER within +0.3 pp of community-1 torch and 3.8-6.7x faster on the synthetic fixtures; not default yet (no vi real-meeting DER, binary not bundled, peak memory not lower).**
4. **Do not adopt:** DiariZen (non-commercial weights), Sortformer 4spk (4-speaker cap), Nemotron-3 (NVIDIA-only), Reverb/Falcon (gated, proprietary).

## 5. Benchmark plan (using existing `pipeline/bench`)

`bench/` has no diarization benchmark yet; `asr_bench.py` builds a synthetic vi/en/code-switched corpus with macOS `say` voices (known speaker per utterance), and `live_eval.py` has interval/coverage helpers. Plan:

1. Add `bench/diar_bench.py` (`make | run <dir> <engine> | all`), each engine in a fresh process like `asr_bench.py` to record peak RSS and wall time.
2. Corpora: (a) the synthetic `say` corpus, stitched with overlaps and 2-6 speakers, giving exact RTTM; (b) 3-5 AMI/VoxConverse test files (public, for sanity against published numbers); (c) 2-3 consented real Vietnamese meetings with hand-corrected speaker turns, copied out of `~/MeetingNotes` by the user (never read in place).
3. Engines: `community-1` (torch MPS and CPU), `3.1`, current wespeaker clustering, `sherpa-onnx` (seg-3.0 + CAM++ and + wespeaker), `Senko`, optional FluidAudio CLI.
4. Metrics: DER (collar 0 and 0.25), JER, speaker-count error, confusion vs missed vs false alarm, plus the downstream metric that matters here: WER/CER of per-speaker transcripts through `live_eval.compare` after `gate`. Also RTF and peak memory on the M1 Pro (16 GB), run while Whisper is loaded.
5. Use `pyannote.metrics` (already a dependency) for scoring.
6. Acceptance: ungated engine within +3 absolute DER of community-1 on corpora (a) and (c) and correct speaker count in at least 80% of files; otherwise keep it as fallback tier only.

## 6. sherpa-onnx adapter: models, licenses, attribution

Built as an opt-in engine (`diarization_engine = "sherpa-onnx"`, `adapters/outbound/sherpa_diarizer.py`,
`sherpa_models.py`; `uv sync --extra sherpa`). Files are fetched on first use from the sherpa-onnx GitHub release
assets (plain HTTPS, 302 to a CDN, no login or token; checked 2026-10-23) into the gitignored `models/sherpa-onnx/`,
and each download is sha256-pinned in `sherpa_models.py`.

| Piece | File | License (verified 2026-10-23) | Attribution |
|---|---|---|---|
| Runtime | `sherpa-onnx` 1.13.8 + `sherpa-onnx-core` (bundles onnxruntime), PyPI wheels | Apache-2.0 (GitHub license API, PyPI metadata) | k2-fsa/sherpa-onnx |
| Segmentation | `sherpa-onnx-pyannote-segmentation-3-0/model.onnx` (6 MB; tarball 7 MB) | MIT: LICENSE file in the tarball, "Copyright (c) 2022 CNRS"; HF card `pyannote/segmentation-3.0` license `mit` (the HF repo itself is gated, the ONNX export is not) | pyannote/segmentation-3.0 (Hervé Bredin, Alexis Plaquet, CNRS), converted by k2-fsa |
| Embedding (default) | `3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx` (28 MB) | Apache-2.0 (ModelScope API, `iic/speech_campplus_sv_zh_en_16k-common_advanced`) | 3D-Speaker CAM++ (Alibaba Tongyi Lab), modelscope/3D-Speaker |
| Embedding (option) | `3dspeaker_speech_campplus_sv_en_voxceleb_16k`, `3dspeaker_speech_eres2net_sv_en_voxceleb_16k` | Apache-2.0 (ModelScope) | 3D-Speaker |
| Embedding (option) | `wespeaker_en_voxceleb_resnet34_LM` | CC-BY-4.0 (WeSpeaker pretrained models follow the VoxCeleb data license); same license as the pyannote wespeaker embedder already used | wenet-e2e/wespeaker |

The release note of the embedding assets says "each model has its own license"; only the names above are
accepted by `sherpa_embedding_model`. If the app ships these files, add the MIT notice (CNRS) and the Apache-2.0
NOTICE lines to the app's third-party notices.

## 7. Measured: pyannote community-1 vs sherpa-onnx (2026-10-23)

`pipeline/bench/diar_bench.py` (diarize stage only: system track, mic voice check or full mic pass, two-track
merge) on the seeded `say` fixtures of `bench/meeting_fixture.py`. M1 Pro 16 GB, **on AC**, nice 10 + utility QoS,
one job at a time, `--repeat 2` (medians; DER and speaker counts were identical across repeats, times within
~10 % except sherpa 60 min 312-394 s). Memory pressure: waited 10 min for "normal" before the first run, never
got a clean run; every run is labelled **warn** (some started "normal"), swap ~17-19 GB used. pyannote =
`speaker-diarization-community-1` on MPS, batch 8; sherpa = segmentation-3.0 ONNX + CAM++ zh_en advanced, CPU 4
threads, fast clustering threshold 0.5. Time = model load + diarize. Peak RSS = process `ru_maxrss` (MPS/Metal
buffers of pyannote are not fully counted).

| Fixture | Engine | Time (load + diarize) | RTF | DER c0 / c0.25 | DER system track | Speakers hyp/ref | Peak RSS |
|---|---|---|---|---|---|---|---|
| 12 min, 1 local + 2 remote | pyannote | 62.4 s (9.0 + 53.5) | 0.074 | 4.2 % / 0.2 % | 5.1 % | 3/3 | 0.73 GB |
| | sherpa | 68.0 s (0.4 + 67.6) | 0.093 | 4.8 % / 0.4 % | 6.3 % | 3/3 | 0.70 GB |
| 12 min, 2 local (in-room) + 2 remote | pyannote | 113.6 s (8.7 + 104.9) | 0.145 | 6.0 % / 1.6 % | 4.6 % | 4/4 | 0.68 GB |
| | sherpa | 130.2 s (0.9 + 129.3) | 0.179 | 9.9 % / 5.0 % | 11.1 % | **5/4** | 0.60 GB |
| 12 min, speaker bleed on mic | pyannote | 64.5 s (8.0 + 56.4) | 0.078 | 4.6 % / 0.3 % | 5.1 % | 3/3 | 0.84 GB |
| | sherpa | 69.2 s (0.4 + 68.8) | 0.095 | 6.6 % / 1.7 % | 9.0 % | **4/3** | 0.64 GB |
| 60 min, 1 local + 3 remote | pyannote | 286.3 s (12.1 + 274.2) | 0.076 | 5.2 % / 1.0 % | 7.2 % | 4/4 | 1.18 GB |
| | sherpa | 353.5 s (0.4 + 353.1) | 0.098 | **15.5 % / 10.8 %** | **28.3 %** | **8/4** | 1.70 GB |
| 12 min, mic check off (full mic pass) | pyannote | 124.9 s | 0.158 | 4.8 % / 0.3 % | 5.1 % | 3/3 | 0.62 GB |
| | sherpa (no torch at all) | 121.8 s | 0.168 | **28.3 % / 23.5 %** | 6.3 % | **5/3** (mic split in 3) | 0.50 GB |

Findings:

1. **sherpa-onnx is not faster here.** With the default mic check it is 7-24 % slower in total (RTF 0.09-0.18 vs
   0.07-0.15); with both tracks diarized in full it is 2 % faster. It skips pyannote's ~9-12 s model load, but its CPU embedding pass is slower than pyannote on MPS.
   Tried on 4 min of the system track: CPU 4 threads 13.1 s, 8 threads 16.8 s, CoreML execution provider 16.7 s,
   so 4 CPU threads is its best setting on this Mac.
2. **Worse speaker counting**, the known weak spot (no VBx/PLDA): one extra speaker on the in-room and bleed
   fixtures, 7 clusters for 3 remote voices on 60 min (DER +10.3 pp), and the single-voice mic split into 3 when
   the mic check is off. On short, clean, two-voice tracks it is within +0.6 pp of pyannote.
3. **Memory:** no torch for the full pass, so RSS is ~0.1-0.2 GB lower on 12 min, and 0.50 GB with the mic check
   off (torch never imported). On 60 min its RSS was higher (1.70 vs 1.18 GB; pyannote's Metal memory is partly
   outside RSS, so the true gap is smaller). Swap deltas were noise under "warn" (-0.9 to +2.1 GB for both engines).
4. **Clustering threshold sweep** (1 run each, warn): 0.9 fixes the over-splitting on 12 min and is now the
   default (`sherpa_cluster_threshold`); 0.7 sits between.

   | Fixture | pyannote | sherpa 0.5 | sherpa 0.7 | sherpa 0.9 |
   |---|---|---|---|---|
   | 12 min | 4.2 %, 3/3 | 4.8 %, 3/3 | - | 4.8 %, 3/3 |
   | 12 min in-room | 6.0 %, 4/4 | 9.9 %, 5/4 | 7.9 %, 4/4 | 7.7 %, 4/4 |
   | 12 min bleed | 4.6 %, 3/3 | 6.6 %, 4/3 | 6.6 %, 4/3 | 5.6 %, 3/3 |
   | 60 min | 5.2 %, 4/4 | 15.5 %, 8/4 | 7.2 %, 5/4 | 7.2 %, 5/4 |

   (DER collar 0, speakers hyp/ref.) At 0.9 sherpa is within +0.6 to +2.0 pp of pyannote and gets the count right
   on 3 of 4 fixtures (60 min still has one extra remote cluster); it stays slower.
5. The plan's adoption bar (DER within +2 pp, speaker count right in >= 80 % of files, >= 5x faster, no rise in
   peak memory) fails on speed (needs >= 5x faster, measured 0.8-1.0x) even after
   tuning; DER (+2 pp) and speaker count (3/4 = 75 % < 80 %) are borderline at 0.9.

**Recommendation:** keep pyannote community-1 as the default. Keep sherpa-onnx as an opt-in, torch-free and
token-free engine only (useful where the HF gate or torch is the problem, not for speed); at threshold 0.9 it
is a reasonable candidate for the ungated fallback tier (instead of agglomerative wespeaker clustering) once it is
checked on real meetings. The speed
lever for Phase 3 is the ANE path (FluidAudio, 3.4), not ONNX on CPU. No Vietnamese real-meeting DER exists yet
(plan 0.2b / 3.2): all numbers are synthetic `say` voices, which are easier to separate than real people.

## 8. Measured: FluidAudio (Core ML community-1 on ANE) vs pyannote (2026-10-23)

**Licenses and download (verified 2026-10-23).** SDK `FluidInference/FluidAudio` Apache-2.0 (GitHub license API),
pinned at release `0.17.7` (SwiftPM `exact:`). It also links the prebuilt `NemoTextProcessing.xcframework`
(FluidInference/text-processing-rs v0.3.1, checksum-pinned by the SDK; unused by diarization). Weights:
`FluidInference/speaker-diarization-coreml`, HF `gated: false`, anonymous HTTPS download works; the SDK pins the
repo to commit `df2625ac79a7ac6b65ad868fee6d80f320da4232`. The offline set (`Segmentation`, `FBank`, `Embedding`,
`PldaRho` `.mlmodelc`, `plda-parameters.json`, `xvector-transform.json`, ~21 MB) is CC-BY-4.0 per the repo's
NOTICE.md (Core ML conversion of pyannote community-1, CC-BY-4.0; PLDA from BUT Speech@FIT, CC-BY-4.0 incl.
commercial); legacy 3.1 conversions in the same repo are MIT (segmentation-3.0) / CC-BY-4.0 (WeSpeaker) and are not
downloaded. Attribution if shipped: pyannote, WeSpeaker, BUT Speech@FIT, Fluid Inference, link CC-BY-4.0, state
"modified Core ML conversion". The SDK reads `HF_TOKEN` if set; our adapter strips it, so no token ever leaves.

**Integration.** `app/Sources/MeetingNotesDiarize` (executable target, imports only Foundation/AVFoundation/CoreML/
FluidAudio, enforced by `check-swift-arch.sh`) runs `OfflineDiarizerManager` (segmentation + WeSpeaker + PLDA + VBx,
community defaults, compute units `.all`) on one WAV and prints JSON turns; `--prepare` downloads and compiles the
models into `models/fluidaudio/`. `adapters/outbound/fluidaudio_diarizer.py` writes each track to a temporary WAV and
shells out (one process per track; Core ML load ~0.3-0.9 s each, included in the times below). Like sherpa, the mic
single-voice check and every failure use pyannote. Not bundled into the app yet.

**Bench.** Same harness and fixtures as section 7 (`diar_bench.py`, M1 Pro 16 GB on AC, nice 10 + utility QoS,
one job at a time, medians of `--repeat 2` unless noted; DER and speaker counts identical across repeats). Every
run **warn** pressure except one m12-bleed run that started and stayed normal; the second m12-bleed run overlapped
~15 s with another agent's pipeline_bench start-up (timing only). `fluidaudio-nocheck` = `mic_voice_check = false`
(mic diarized by FluidAudio too, torch never imported), one run. Peak RSS = Python process; CLI = largest child
(`RUSAGE_CHILDREN`, new `child_rss_gb` column), so the true peak is at most their sum. pyannote rows from section 7.

| Fixture | Engine | Time (load + diarize) | Speed-up | DER c0 / c0.25 | DER system | Speakers hyp/ref | Peak RSS (Python + CLI) |
|---|---|---|---|---|---|---|---|
| 12 min, 1 local + 2 remote | pyannote | 62.4 s | 1x | 4.2 % / 0.2 % | 5.1 % | 3/3 | 0.73 GB |
| | fluidaudio | 16.6 s | 3.8x | 4.4 % / 0.2 % | 5.5 % | 3/3 | 0.66 + 0.40 GB |
| | fluidaudio-nocheck | 10.8 s | 5.8x | 5.1 % / 0.3 % | 5.5 % | 3/3 | 0.43 + 0.45 GB (no torch) |
| 12 min, 2 local + 2 remote | pyannote | 113.6 s | 1x | 6.0 % / 1.6 % | 4.6 % | 4/4 | 0.68 GB |
| | fluidaudio | 20.3 s | 5.6x | 6.0 % / 1.4 % | 4.9 % | 4/4 | 0.66 + 0.42 GB |
| 12 min, speaker bleed on mic | pyannote | 64.5 s | 1x | 4.6 % / 0.3 % | 5.1 % | 3/3 | 0.84 GB |
| | fluidaudio | 13.4 s | 4.8x | 4.9 % / 0.4 % | 5.6 % | 3/3 | 0.77 + 0.44 GB |
| | fluidaudio-nocheck | 13.1 s | 4.9x | 5.4 % / 0.5 % | 5.6 % | 3/3 | 0.43 + 0.41 GB (no torch) |
| 60 min, 1 local + 3 remote | pyannote | 286.3 s (12.1 + 274.2) | 1x | 5.2 % / 1.0 % | 7.2 % | 4/4 | 1.18 GB |
| | fluidaudio | 42.8 s (35.4-50.3) | 6.7x | 5.5 % / 1.2 % | 7.8 % | 4/4 | 1.54 + 0.61 GB |
| | fluidaudio-nocheck | 53.2 s | 5.4x | 6.3 % / 1.4 % | 7.8 % | 4/4 | 1.31 + 0.58 GB (no torch) |

Findings:

1. **Quality matches community-1 torch:** +0.0 to +0.3 pp DER with the default mic check, speaker count right on
   4/4 fixtures (sherpa: 1-3 wrong). Torch-free (mic diarized too) it stays within +1.1 pp and counts right, unlike
   sherpa (28 % DER, mic split in 3). Same model family, so this is expected; vendor numbers (VoxConverse +3 pp vs
   torch) are not reproduced on these fixtures.
2. **Fast:** 3.8-6.7x less wall time (RTF 0.012-0.027 vs 0.074-0.145), largest on 60 min; no 9-12 s model load.
   Most of the remaining 12 min time is the pyannote mic voice check (torch import + embeddings): without it the
   12 min fixture takes 10.8 s.
3. **Memory is not lower:** the CLI peaks at 0.40-0.61 GB while the Python process still holds the decoded tracks
   (and torch for the voice check); on 60 min the Python side measured 1.54 GB vs 1.18 GB for pyannote (whose
   Metal buffers are partly outside RSS). Swap deltas are noise under warn.
4. Against the plan's default bar: DER within +2 pp, speaker count right, >= 5x on 60 min all pass on the
   synthetic set; "no rise in peak memory" fails on this measure, and the vi real-meeting set (3.2) is missing.

**Update (2026-10-23): FluidAudio is now the default** (user decision): the helper is bundled in the app, pyannote
(HF_TOKEN) and the ungated clustering are the fallback chain, and the vi real-meeting check (3.2) is still to do.

**Original recommendation:** keep pyannote as the default for now; ship FluidAudio as the opt-in fast engine (committed:
`diarization_engine = "fluidaudio"`, `fluidaudio_cli`). Next: run it on the vi real-meeting set (3.2); if it holds,
bundle the helper (+ CC-BY notices) via `scripts/build-app.sh` and make it the default with pyannote as fallback; a
FluidAudio-based mic voice check would drop torch from the diarize stage entirely.

## Sources

- pyannote community-1 card: https://huggingface.co/pyannote/speaker-diarization-community-1
- DiariZen: https://github.com/BUTSpeechFIT/DiariZen , https://huggingface.co/BUT-FIT/diarizen-wavlm-large-s80-md
- Nemotron-3-Diarization: https://huggingface.co/nvidia/Nemotron-3-Diarization
- Sortformer 4spk v2.1: https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1
- sherpa-onnx diarization docs: https://k2-fsa.github.io/sherpa/onnx/speaker-diarization/index.html ; license: https://github.com/k2-fsa/sherpa-onnx/blob/master/LICENSE ; release assets: https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-segmentation-models
- 3D-Speaker: https://github.com/modelscope/3D-Speaker ; WeSpeaker: https://github.com/wenet-e2e/wespeaker
- Senko: https://github.com/narcotic-sh/senko
- FluidAudio: https://github.com/FluidInference/FluidAudio , benchmarks https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md , models https://huggingface.co/FluidInference/speaker-diarization-coreml
- Reverb: https://huggingface.co/Revai/reverb-diarization-v1
- Head-to-head (vendor-run): https://soniqo.audio/benchmarks/diarization
- SDBench: https://www.isca-archive.org/interspeech_2025/durmus25_interspeech.pdf
