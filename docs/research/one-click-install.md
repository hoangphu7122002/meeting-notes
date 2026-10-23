# One-click install: research and design

Status: research only (no code changed). Date: 2026-10-23. Constraint (user decision): no Apple Developer account, so no Developer ID signing or notarization; distribution through GitHub Releases. Target: a colleague with an Apple Silicon Mac (M1 Pro 16 GB baseline), no terminal, no Hugging Face account.

Colleague feedback: "Installing needs too many things, even a Hugging Face login; we want one-click install."

**Update (2026-10-23, implemented): one-pass dev install, no Hugging Face login.** The default diarizer is now
FluidAudio (Core ML port of community-1, ungated weights, no token; `diarization-alternatives.md` section 8), bundled
as `MeetingNotesDiarize` in the app; pyannote with `HF_TOKEN` is only a fallback. Steps 9-12 below are gone, and
steps 2 and 4-8 are one command, `make install` (`scripts/install.sh`): it checks the Mac (macOS 14+, Apple Silicon,
Xcode CLT, running app), prints what it will install, installs missing Homebrew (official installer)/uv/ffmpeg/Ollama,
runs `uv sync`, builds the helper, `meeting-notes setup` (whisper, embeddings, FluidAudio, Ollama model), builds and
installs the app, runs `doctor` and prints the permission steps. Idempotent; `--dry-run` changes nothing; a recording
MeetingNotes is never quit unless `--force`. A new user now does: Xcode CLT, `git clone`, `make install`, 2
permissions. The no-terminal dmg path (option B, sections 5-6) is still open.

**Update (2026-10-23, implemented): option B dmg + first-run wizard (not yet published).** `scripts/release.sh`
builds a 31 MB self-signed `MeetingNotes-<version>.dmg`; the app's setup card downloads the rest itself (section 6
option B, without bundled pyannote weights: FluidAudio is the default). Newcomer steps: download dmg, drag to
Applications, Open Anyway once, Set up, install Ollama from ollama.com if the card asks, 2 permissions. Details and
checklist: [`docs/release.md`](../release.md).

## Shared install (several macOS accounts)

Implemented 2026-10-23: `make install-shared` = `scripts/install.sh --shared` (logic in `scripts/install-shared.sh`,
`--dry-run` supported). Goal: one Mac, several accounts (e.g. `hoangphu` and `phu_strata`), one copy of the software
and models, everything private stays per account.

| What | Where | Who writes |
|---|---|---|
| App (+ bundled `MeetingNotesDiarize`) | `/Applications/MeetingNotes.app`; `/Users/Shared/MeetingNotes/MeetingNotes.app` when the installing account cannot write `/Applications` (not admin) | installing account |
| Pipeline source, `.venv` (uv-managed Python 3.12 in `python/`), `bin/uv` | `/Users/Shared/MeetingNotes/{pipeline,python,bin}` | installing account; others read only |
| Models: whisper + embeddings (HF hub cache), FluidAudio | `/Users/Shared/MeetingNotes/models/{huggingface/hub,fluidaudio}` | installing account; others read only |
| Marker | `/Users/Shared/MeetingNotes/shared-install.json` (`pipeline_dir`, `uv_path`, `hf_hub_cache`, `app`) | installer |
| Recordings, `config.toml`, `.env` (HF_TOKEN), logs, `state.json`, uv/MLX/Core ML caches, TCC grants, Launch at Login | each account's home (`~/MeetingNotes`, `~/.config/meeting-notes`, `~/Library`) | that account |

How it resolves:
- **App** (`PipelineLocator`, Core, tested): defaults override, Info.plist `MNPipelineDir` (baked to the shared
  pipeline by `build-app.sh --pipeline-dir`), `MN_PIPELINE_DIR`, then `/Users/Shared/MeetingNotes/shared-install.json`.
  When the marker sits next to the pipeline dir, the app uses the shared `bin/uv` (never a uv in someone's home) and
  starts the worker with `UV_NO_SYNC=1 UV_FROZEN=1 UV_PYTHON_DOWNLOADS=never`: `uv run` on a read-only project
  otherwise tries to re-sync and fails (verified: exit 2, permission denied; with the flags it runs from a fresh HOME).
- **Pipeline** (`config/install.py`): the CLI sets `HF_HUB_CACHE` to the shared hub before any HF import and
  `HF_HUB_OFFLINE=1` when this account cannot write it (verified: offline loads from a read-only cache, no lock files).
  FluidAudio models are `<root>/models/fluidaudio` as before (loading compiled models writes nothing).
  `hf_token()` reads the environment, then `~/.config/meeting-notes/.env`, and the repo `.env` only in a dev install;
  the installer refuses a `.env` inside the shared root and copies only the `HF_TOKEN` line of the repo `.env` to the
  installing account's `~/.config/meeting-notes/.env` (mode 600, never printed).
- **Safety**: the shared root must be owned by the installing account and not group/world-writable (`/Users/Shared`
  itself is world-writable, so someone else could pre-create it); files are `chmod -R u+rwX,go+rX,go-w`. The script
  never runs sudo; without admin rights it installs the app in the shared root and prints the `sudo ditto` command.
  It refuses while another account runs the shared app or pipeline (it cannot and must not quit them; fast user
  switching), never quits a recording app, and never moves a running per-user `~/Applications` copy.

Steps:
1. Installing (admin) account, once: `make install-shared ARGS=--dry-run`, then `make install-shared`. Open
   `/Applications/MeetingNotes.app`; grants usually carry over (same signature and bundle id); re-enable Launch at
   Login; move the old `~/Applications/MeetingNotes.app` to the Trash when asked (two copies confuse LaunchServices).
2. Every other account, once, logged in as that account: `/Users/Shared/MeetingNotes/bin/meeting-notes-user-setup --open`
   (creates `~/MeetingNotes` and `~/.config/meeting-notes`, runs `doctor --offline`, checks Ollama, prints the
   steps), then allow Microphone and Screen & System Audio Recording. TCC grants are per account; no admin needed.
3. Updates: re-run `make install-shared` from the installing account while the other accounts have quit the app.

Ollama (summaries stay on 127.0.0.1, never a cloud LLM):

| Option | Duplicate models | Setup | Trade-off |
|---|---|---|---|
| **A. One server (default)**: the installing account's Ollama (`brew services`, LaunchAgent) on `127.0.0.1:11434` serves every account | none | none for other accounts | Runs while that account is logged in (it keeps running under fast user switching). Another account's transcript text is processed in memory by a process of the installing account (loopback only; Ollama stores no prompts unless `OLLAMA_DEBUG`). If it is down, notes are written without a summary; Reprocess adds it later |
| B. Per-account server on another port, models read from a shared store: move the installer's models to e.g. `/Users/Shared/MeetingNotes/ollama` (`OLLAMA_MODELS`, read-only for others), others run `OLLAMA_HOST=127.0.0.1:11435 OLLAMA_MODELS=... OLLAMA_NOPRUNE=1 ollama serve` and set `ollama_url = "http://127.0.0.1:11435"` | none | per account | Strict process isolation; moving `~/.ollama/models` (7 GB today) and keeping both servers configured is manual |
| C. Per-account server with its own models (`ollama_url` on another port) | qwen3:4b, 2.5 GB per account | per account | Simplest isolation, costs disk; two servers cannot share port 11434 |

A is the default because it needs nothing and duplicates nothing; the two accounts belong to the same person. Use B or C
when accounts belong to different people.

Concurrent use (fast user switching): no shared writable state at run time. Each account has its own app process,
worker, `state.json`, TMPDIR (`/var/folders/...`), uv cache, MLX and Core ML caches; the shared store is read-only for
non-owners and offline. Risks: two loaded whisper models (~1-2 GB each) plus Ollama on 16 GB; macOS may not deliver
microphone or system audio to an account that is switched out, so check a recording made in a background session
before relying on it.

Disk: a second per-user install would cost ~4.4 GB (venv 1.4 GB, whisper 0.46 GB, embeddings + FluidAudio 0.05 GB,
qwen3:4b 2.5 GB). Shared: ~2 GB once (venv, Python ~0.1 GB, models; on APFS the venv is cloned from the uv cache) and
~0 per extra account.

## 1. What a new user does today

Source: `README.md`, `scripts/install.sh`, `scripts/build-app.sh`, `scripts/setup-signing.sh`, `meeting-notes setup` (`adapters/inbound/commands.py`), app first run (`PermissionsCard`).

| # | Step | Where | Download | Time (approx., 100 Mbps) |
|---|---|---|---|---|
| 1 | Install Xcode Command Line Tools (`xcode-select --install`), needed for `swift build` | Terminal + dialog | ~0.7-1 GB | 5-15 min |
| 2 | Install Homebrew (sudo password) | Terminal | ~0.1 GB | 2-5 min |
| 3 | `git clone` the repo to `~/meeting-notes` (path is baked into the app) | Terminal | small | <1 min |
| 4 | `scripts/install.sh` → `brew install uv` (47 MB binary) | Terminal | ~20 MB | <1 min |
| 5 | → `brew install ffmpeg ollama`, `brew services start ollama` | Terminal | ffmpeg + deps, ollama ~0.2 GB | 2-8 min |
| 6 | → `uv sync`: Python 3.12 env, 131 locked packages (torch 127 MB, mlx-metal 45 MB, llvmlite 41 MB, scipy 29 MB ...). The current `.venv` links Homebrew `python@3.12`, a hidden dependency | Terminal | ~0.35 GB wheels, 1.4 GB on disk | 1-3 min |
| 7 | → `meeting-notes setup`: whisper `mlx-community/whisper-large-v3-turbo-q4` (464 MB), `pyannote/wespeaker-voxceleb-resnet34-LM` (27 MB), `qwen3:4b` via Ollama (2.50 GB), pyannote `community-1` (34 MB) only if the HF token has access | Terminal | ~3.0 GB | 4-6 min |
| 8 | → `build-app.sh`: `swift build -c release`, creates a self-signed cert in a new keychain, codesigns, installs `~/Applications/MeetingNotes.app` | Terminal | - | 1-3 min |
| 9 | Create a Hugging Face account | Browser | - | 2-3 min |
| 10 | Accept the gate on `pyannote/speaker-diarization-community-1` (company + use case form); optionally also `speaker-diarization-3.1` and `segmentation-3.0` | Browser | - | 1-2 min |
| 11 | Create an HF access token, write `HF_TOKEN=...` into `~/meeting-notes/.env` | Browser + editor | - | 2 min |
| 12 | Re-run `meeting-notes setup` (or `doctor`) so community-1 is fetched/verified | Terminal | 34 MB | <1 min |
| 13 | Open app, allow Microphone | Dialog | - | <1 min |
| 14 | Enable Screen & System Audio Recording in System Settings, relaunch the app | System Settings | - | 1 min |
| (15-16) | Optional: notifications, Launch at Login approval | Dialog / Settings | - | - |

Total: **14 required steps** (8 terminal/build, 4 browser/token, 2 permissions), ~4.5 GB downloaded, ~6 GB on disk, roughly 25-45 min and Xcode CLT + Homebrew as prerequisites. The app is not relocatable: `Info.plist` bakes `MNPipelineDir` (repo path) and `MNUvPath`, and `hf_token()` reads `.env` from the repo root, so every user must build from source.

## 2. Why Hugging Face login is needed

Root cause: the default diarization pipelines `pyannote/speaker-diarization-community-1` and `pyannote/speaker-diarization-3.1` (plus `segmentation-3.0`) are **gated** on HF (`gated: auto`: click-through form that collects company/use case for pyannote's marketing). The **licenses are permissive**; the gate is a lead-capture form, not a license term. `Diarizer.pipeline()` refuses to even try without `HF_TOKEN`. Without it the pipeline falls back to clustering ungated wespeaker embeddings (weaker on similar voices).

| Model | Gated | License | Size | Redistribution / mirror without token |
|---|---|---|---|---|
| `pyannote/speaker-diarization-community-1` | yes (auto) | CC-BY-4.0 | 33.7 MB (segmentation 5.9 + embedding 26.6 + PLDA 0.3) | Allowed with attribution (CC-BY-4.0). Card documents offline use: `Pipeline.from_pretrained('/local/dir')` |
| `pyannote/speaker-diarization-3.1` | yes (auto) | MIT | config only (uses segmentation-3.0) | Allowed (keep MIT notice) |
| `pyannote/segmentation-3.0` | yes (auto) | MIT | 5.9 MB | Allowed (keep MIT notice) |
| `pyannote/wespeaker-voxceleb-resnet34-LM` | no | CC-BY-4.0 | 26.6 MB | Allowed with attribution |
| `mlx-community/whisper-large-v3-turbo-q4` | no | no tag; derived from OpenAI Whisper (MIT) | 464 MB | Not needed (ungated). `mlx-community/whisper-large-v3-turbo-4bit` is tagged Apache-2.0 if a clear license tag is wanted |
| Ollama `qwen3:4b` | no | Apache-2.0 | 2.50 GB | Not needed (Ollama registry) |

Existing ungated mirror: `pyannote-community/speaker-diarization-community-1` ("Unofficial Pyannote Community", unverified, 1 member, created 2025-10-15). Verified today: every LFS file has the **same sha256** as the gated original. Usable, but it is a third-party account serving pickled `pytorch_model.bin` files, so pin revision + sha256 if used, or better mirror it ourselves.

## 3. Ungated diarization alternatives (M1 Pro 16 GB)

DER figures from the pyannote community-1 card (lower is better): AMI-SDM 22.7 (3.1) → 19.9 (community-1); DIHARD3 21.4 → 20.2; VoxConverse 11.2 → 11.2. Other rows are qualitative; benchmark on our own Vi/En recordings before switching.

| Option | Gated | License | Download | Quality vs today's best | Speed on M1 Pro | Effort | Notes |
|---|---|---|---|---|---|---|---|
| **community-1 bundled in the app (local dir)** | no | CC-BY-4.0 | 34 MB | Same | Same (torch, MPS/CPU) | 0.5-1 day | Recommended. Ship the files + attribution inside the app, load via local dir; no public mirror needed |
| community-1 via `pyannote-community` mirror | no | CC-BY-4.0 | 34 MB | Same | Same | 0.5 day | Third-party trust risk; pin revision + sha |
| 3.1 + segmentation-3.0 mirrored | no | MIT | 6 MB + wespeaker 27 MB | Slightly worse (see DER) | Same | 0.5 day | Only as a fallback |
| Current fallback: wespeaker + agglomerative clustering | no | CC-BY-4.0 | 27 MB | Worse; merges similar voices on one track | Fast | 0 | Already works with no token |
| sherpa-onnx (pyannote segmentation-3.0 ONNX 7 MB + wespeaker/3D-Speaker ONNX embeddings, GitHub releases) | no | Apache-2.0 code; MIT / CC-BY model files | ~30-40 MB, onnxruntime instead of torch | Close to 3.1 segmentation, simpler clustering (threshold or fixed count, no VBx/PLDA), so weaker speaker counting | Fast on CPU | 2-4 days | Could drop torch (574 MB on disk) from the env |
| FluidAudio (Swift, Core ML/ANE port of community-1, `FluidInference/speaker-diarization-coreml`) | no | Apache-2.0 code; models "scoped CC-BY-4.0" | 129 MB | Ported from community-1; verify parity | Fastest (ANE), no Python | 1-2 weeks | Moves diarization into Swift: breaks the frozen app-pipeline contract |
| NVIDIA Streaming Sortformer 4spk v2 | no | CC-BY-4.0 (v1 is CC-BY-NC, unusable) | 639 MB | Strong but max 4 speakers | Heavy (NeMo + torch) | 1-2 weeks | Not worth it here |
| Rev `reverb-diarization-v2` | yes | other (non-commercial terms) | 423 MB | - | - | - | Rejected (gated + license) |

## 4. Other friction removers

| Item | Today | Proposal | Effort |
|---|---|---|---|
| Xcode CLT, Homebrew, git clone, swift build | Required | Ship a prebuilt `.app` in a `.dmg` (CI or local release script) | part of option B |
| Python | `uv` from brew, venv on Homebrew Python | Bundle `uv` (47 MB, MIT/Apache) in the app; `UV_PYTHON_PREFERENCE=only-managed` downloads python-build-standalone 3.12 (25 MB); env in `~/Library/Application Support/MeetingNotes/` via `UV_PROJECT_ENVIRONMENT` (never inside the signed bundle) | part of B |
| ffmpeg | brew; used to decode imports and encode `.m4a` copies | Use macOS `afconvert`/AVFoundation for m4a and common formats; keep ffmpeg optional (only for webm/mkv imports). Bundling ffmpeg means GPL/LGPL compliance. Verify pyannote 4 / torchcodec import is fine without ffmpeg libs (we pass in-memory waveforms) | 0.5-1 day |
| Ollama | brew + `brew services` | Detect `127.0.0.1:11434`; if absent, either download official Ollama.app (220 MB zip) or run a bundled headless `ollama` (181 MB, MIT) as a child process with `OLLAMA_MODELS` in Application Support | 1-1.5 days |
| HF token / `.env` | Required for best speakers | Not needed (section 3). Keep `HF_TOKEN` as an optional override (public API) | 0.5-1 day |
| Permissions | Mic + Screen & System Audio, relaunch | Keep the existing checklist as the last wizard step. Sign every release with one stable self-signed certificate (today's `setup-signing.sh` approach, key kept by the release builder) so grants survive updates; ad-hoc signing would reset them on every update | - |
| Gatekeeper | Not applicable (built locally) | No Apple Developer account (user decision): one-time "Open Anyway", see section 5 | see section 5 |

## 5. Distribution without an Apple Developer account (GitHub Releases)

### 5.1 Gatekeeper on an unsigned (self-signed) app

- Any file a browser downloads gets `com.apple.quarantine`. Since macOS 15, right-click › Open no longer bypasses Gatekeeper for apps that are not notarized; the user must double-click once, then System Settings › Privacy & Security › **Open Anyway** › admin password. This is **once per browser-downloaded copy**.
- An "installer" cannot remove the gate for itself: an unsigned `.pkg`, `.command` script or helper app is quarantined too and hits the same prompt. So one approval is unavoidable for a browser download. Make it one approval total:
  1. Ship `MeetingNotes.dmg` with the app and an Applications alias (drag to install, which also avoids App Translocation). The dmg window shows a 3-step picture of "Open Anyway".
  2. After the first approval, the app does everything else itself: its own downloads (URLSession / `uv` / Ollama) are not quarantined (keep `LSFileQuarantineEnabled` unset), and an in-app updater that downloads the next dmg/zip and swaps the bundle needs no further approval.
  3. If the app finds itself under `/AppTranslocation/` or outside an Applications folder, the wizard asks the user to move it (TCC grants and updates need a stable path).
- Terminal fallback for power users (no System Settings detour): `xattr -dr com.apple.quarantine /Applications/MeetingNotes.app`, or download with `curl -L`/`gh release download`, which do not set quarantine.
- Signing: Apple Silicon requires at least an ad-hoc signature. Sign every release with **one stable self-signed certificate** (today's `scripts/setup-signing.sh` identity, private key kept only on the release machine or as a CI secret). The TCC designated requirement (bundle id + certificate leaf hash) then stays the same, so Microphone and Screen & System Audio grants survive updates. Ad-hoc signing would reset them on every update. No hardened runtime or entitlements work is needed without notarization.
- Optional Homebrew cask in a tap: not recommended. Homebrew applies quarantine by default and is phasing out casks that fail Gatekeeper, and it brings back the Homebrew prerequisite.

### 5.2 Repository access

The brief says the repo is private; the GitHub API reports `hoangphu7122002/meeting-notes` as **public** today (checked 2026-10-23). Either way:

| Option | Colleague needs | In-app downloads / auto-update | Notes |
|---|---|---|---|
| Private repo, colleagues added as collaborators (read) | GitHub account, invite accepted, logged-in browser to download the release asset | **No**: release assets of a private repo need a token, which would bring back a token step. First-run downloads must then come only from public upstreams (HF, Ollama, PyPI); updates are manual | Code stays private. Free personal accounts allow unlimited private collaborators |
| Private code repo + separate **public** `meeting-notes-releases` repo holding only dmg/zip + release notes | Just a link | Yes: the app can poll the public Releases API and self-update with no account | Binaries (and bundled CC-BY/MIT weights, with attribution) become public; source stays private |
| Code repo itself public (current state per API) | Just a link | Yes | Everything public |

### 5.3 Asset size limits and what to bundle

GitHub Releases: each asset must be under 2 GiB; GitHub states no limit on total release size or bandwidth. macOS Actions runners on a private repo bill minutes at a 10x multiplier (free plan: 2,000 min/month ≈ 200 macOS minutes); building and uploading locally with `gh release create` avoids that.

| Payload | Size | Bundle in release? | Reason |
|---|---|---|---|
| App + `uv` binary + pipeline source + `uv.lock` | ~60-80 MB compressed | Yes (the dmg) | Core |
| pyannote community-1 + wespeaker weights | 61 MB | **Yes, inside the app** | Removes the HF gate and the need for any public weight mirror; CC-BY-4.0 allows it with attribution (NOTICE in the app + Settings › About) |
| Python 3.12 standalone + wheels | ~0.37 GB (1.4 GB installed) | Optional (B-offline) | First-run download from PyPI/GitHub via `uv` is simpler; bundling makes each update ~0.45 GB |
| Whisper turbo q4 | 464 MB | No (first run, HF, ungated, resumable) | Would make every update download it again; could be a separate one-time asset if HF is blocked on a network |
| `qwen3:4b` | 2.50 GB | **Cannot** as one asset (> 2 GiB) | Ollama manages its own store: pull from the Ollama registry at first run |
| Ollama runtime | 181-220 MB | No (download official build on demand, or reuse an existing install) | Separate update cycle |

Resulting dmg: **~0.1-0.15 GB** (or ~0.5 GB for B-offline). First-run download: ~3.4 GB (Python env, whisper, Ollama if absent, `qwen3:4b`).

## 6. Options ranked (no notarization)

| Rank | Option | User steps after | Effort | Main costs / risks |
|---|---|---|---|---|
| 1 (do first) | **A. Remove the HF token**: ship community-1 (+ wespeaker) as a local dir, load with `Pipeline.from_pretrained(<dir>)`, sha256-pinned; fallback chain and optional `HF_TOKEN` override unchanged | 10 (removes steps 9-12) | 0.5-1 day | None outward-facing if bundled in a private distribution; public if the dmg is public |
| 2 (recommended) | **B. Self-signed dmg on GitHub Releases + in-app setup wizard**: app bundles `uv`, pipeline source, `uv.lock` and the diarization weights; first launch shows "Set up (≈3.4 GB)", one button runs `uv sync --frozen` (managed Python, env in Application Support), `meeting-notes setup --json` (whisper), Ollama detect/install + `qwen3:4b` pull, each with progress/ETA/retry, then the permission checklist. Includes A and the ffmpeg removal; in-app updater only if releases are public | 5-6: download dmg, drag to Applications, open + **Open Anyway** (once), click "Set up" (~5-15 min wait), grant 2 permissions | 4-6 days + 0.5-1 day release script (build, sign with the stable cert, `hdiutil` dmg, `gh release create`) + 1 day updater (public releases only) | Packaged-mode paths (`MNPipelineDir` → bundle, config/`.env` → Application Support) alongside today's dev mode; runtime downloads from PyPI + GitHub extend AGENTS rule 1; private repo ⇒ manual updates |
| 2b | B-offline: also ship standalone Python + wheelhouse in the dmg | Same | +1 day | dmg ~0.5 GB per update; no PyPI at runtime |
| 3 | C. Fully frozen Python inside the .app (PyInstaller / relocatable venv) | Same as B | 2-3 weeks | ~1.5 GB bundle per update, torch/mlx freezing quirks; without notarization there is no signing benefit to offset it |
| 4 (long term) | D. Native Swift ML (WhisperKit or mlx-swift + FluidAudio + Ollama HTTP), no Python | Same as B, ~3 GB smaller install | 4-8 weeks | Rewrite; breaks the frozen app-pipeline contract; full re-benchmark |
| - | Better `install.sh` / `curl \| sh` | Terminal | 0.5 day | Not "one click"; excluded per brief (kept only as the power-user fallback) |

Wizard design notes:
- Idempotent, resumable steps with size, progress, ETA and Retry; recording works before setup finishes (notes are created once it does).
- A separate `meeting-notes setup --json` process emits the existing progress event shape, so the frozen worker protocol does not change.
- Pin every artifact by revision + sha256; reuse an existing Ollama install and its models.
- Dev mode (repo clone + `scripts/install.sh` + `build-app.sh`) stays as is; packaged mode is detected by the pipeline living inside the bundle.

## 7. Decisions needed from the user

1. **Release visibility**: keep everything private (collaborator invites, manual updates, no in-app updater), or publish binaries in a separate public releases repo (link-only install, in-app updates). Note the code repo currently reads as public via the GitHub API.
2. **Bundling pyannote weights in the app** (CC-BY-4.0, with attribution). Legal, but it bypasses pyannote's lead-capture gate and becomes public if releases are public. Alternative: the unofficial `pyannote-community` HF mirror (identical sha256, third-party trust).
3. **Release signing key**: who holds the self-signed certificate's private key (one Mac vs a CI secret). Losing it means every user re-grants permissions once.
4. **Ollama strategy**: download the official Ollama app on demand (simplest, separate updates) or bundle/manage a headless `ollama` (+181 MB, our app controls it).
5. **Runtime network scope**: allow first-run downloads from PyPI and GitHub (Python, wheels) in addition to HF and the Ollama registry (extends AGENTS rule 1), or ship them in a larger dmg (B-offline).
6. **ffmpeg**: drop it (AVFoundation/`afconvert`; webm/mkv imports then need ffmpeg installed separately) or bundle an LGPL build with license notices.
7. **Distribution identity**: keep bundle id `com.hoangphu.meetingnotes` (personal) or switch to a company id before the first release (switching later resets permissions).
