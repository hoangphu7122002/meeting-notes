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
2. **Fallback candidate to evaluate:** sherpa-onnx (or Senko) as an ungated, torch-free second tier replacing the current agglomerative fallback. Likely better than the present fallback at near-zero download cost.
3. **Watch/optional:** FluidAudio CLI as an opt-in fast path (ANE, community-1 weights) if diarization time on M1 Pro matters.
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
