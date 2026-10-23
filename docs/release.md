# Releases (trunk-based, dmg for newcomers)

What a release is: `MeetingNotes-<version>.dmg` on GitHub Releases, built and published by GitHub Actions when a
`vX.Y.Z` tag is pushed from `master`. A newcomer downloads it, drags the app to Applications, approves it once in
System Settings (Open Anyway: no Apple Developer account, so the app is self-signed and not notarized), opens it and
presses **Cài đặt / Set up**. The app's first-run setup downloads the rest (~3.4 GB): Python 3.12 + locked wheels
(uv), whisper, FluidAudio, then checks Ollama (guides to ollama.com, never installs it) and pulls the summary
model. No terminal, no Hugging Face token.

## Flow

- `master` is always releasable. Work on short-lived branches, open a PR, merge to `master` when CI is green.
  Small direct pushes to `master` are fine; CI runs on them too. No release branches.
- **CI** (`.github/workflows/ci.yml`, every PR and push to `master`, `macos-15` arm64): `make lint-arch`,
  `make lint` (+ `swift build`), `make test` (pytest without e2e, `HF_HUB_OFFLINE=1`, `UV_LOCKED=1`; `swift test`).
  uv and SwiftPM are cached; a newer push to a PR cancels its older run. e2e tests need model weights: local only
  (`make test-e2e`).
- **Edge build**: every green push to `master` also builds the dmg and uploads it as a workflow artifact
  `MeetingNotes-<version>-edge.<n>+g<sha>` (kept 14 days: Actions › ci › the run › Artifacts). Never a Release.
- **Version** = the git tag `vX.Y.Z` (`scripts/version.sh`, `make version`): a tagged commit builds `X.Y.Z`, an
  untagged one the latest tag's version (`0.0.0` before the first tag). `release.sh` stamps it into Info.plist
  `CFBundleShortVersionString`; `CFBundleVersion` is the build timestamp. No VERSION file and no bump commits;
  `pipeline/pyproject.toml` `version` is not the app version.
- **Release** = push a tag `vX.Y.Z` that points at a `master` commit. `.github/workflows/release.yml` reruns the CI
  checks, builds with `scripts/release.sh --version X.Y.Z` and publishes the GitHub Release with
  `MeetingNotes-X.Y.Z.dmg`, `SHA256SUMS.txt` and auto-generated notes (install steps prepended). A tag on a commit
  that is not on `master` fails.
- **Hotfix** = fix on `master` (PR or push), wait for green, tag the next patch `vX.Y.(Z+1)`.

## Cut a release

```sh
git switch master && git pull --ff-only
make release-tag VERSION=X.Y.Z   # checks: on master, clean, equal to origin/master, CI green for HEAD (gh; or
                                 # LOCAL_CI=1 runs make ci here), newer than the last tag; creates the annotated
                                 # tag and prints the push command; never pushes
git push origin vX.Y.Z           # starts release.yml (watch: gh run watch)
```

Undo before pushing: `git tag -d vX.Y.Z`. After a bad release: `gh release delete vX.Y.Z --cleanup-tag` and tag the
next patch; never move a published tag.

Manual run (Actions › release › Run workflow, on `master`, version `X.Y.Z`): `publish` off = test build, workflow
artifact only; `publish` on = creates the tag and the Release from that commit.

## Signing

No Apple Developer account, so no notarization: users approve the app once with **Open Anyway** (dmg read-me).
macOS ties the Microphone and Screen & System Audio grants to the signature:

- **Stable self-signed identity** (`MeetingNotes Local Signing`, `scripts/setup-signing.sh`): grants survive
  updates. CI signs with it when the repo secrets `MACOS_SIGNING_P12_BASE64` and `MACOS_SIGNING_P12_PASSWORD` are
  set (`scripts/ci-signing.sh` imports it into a throwaway keychain). Set them once, on the release Mac:

  ```sh
  security export -k ~/Library/Keychains/meetingnotes-signing.keychain-db -t identities -f pkcs12 \
    -P "<new p12 password>" -o /tmp/mn-signing.p12   # keychain password: ~/.config/meeting-notes/signing-keychain.pass
  base64 -i /tmp/mn-signing.p12 | gh secret set MACOS_SIGNING_P12_BASE64
  gh secret set MACOS_SIGNING_P12_PASSWORD           # paste the p12 password at the prompt
  rm -P /tmp/mn-signing.p12
  ```

  Losing that key means everyone re-grants once.
- **Ad-hoc** (no secrets; the state today): the dmg works, but after every update users grant Microphone and Screen
  & System Audio again (the Release notes say so). Moving from ad-hoc to the stable identity also resets them once.

A local `scripts/release.sh --version X.Y.Z` (`make release`) signs with the local stable identity and never
installs, quits the running app or touches `/Applications`; use it to test a dmg. Publishing goes through the tag.

## Before tagging (manual checks)

1. Smoke test the edge dmg of the commit you will tag (or a local build) without installing: `hdiutil attach
   MeetingNotes-*.dmg`, check the window (app, Applications link, read-me), `codesign -dvv` the app, `hdiutil detach`.
2. Fresh-Mac acceptance (plan Phase 7 M7), in a new macOS user account or a colleague's Mac: browser download →
   drag to Applications → Open Anyway → Set up → Ollama guide → 2 permissions → a 2 min test meeting produces notes;
   then install the next version over it and confirm only the runtime step re-runs (and, with the stable identity,
   that permissions survive).
3. Never commit `build/` or a `.dmg`.

Runner minutes: GitHub-hosted macOS runners are free for this public repo. A private repo would bill macOS minutes
at 10x; each CI run is ~10-15 min, plus about as much for the edge dmg on `master` pushes.

## What is in the dmg

| Item | Source |
|---|---|
| `MeetingNotes.app` (Info.plist `MNPackaged`, version = release) | `scripts/build-app.sh --packaged` |
| `Contents/MacOS/{MeetingNotes, MeetingNotesDiarize, MeetingNotesCaptions, MeetingNotesLauncher, uv}` | `swift build -c release`, the build machine's uv |
| `Contents/Resources/pipeline/` (source, `pyproject.toml`, `uv.lock`) | `pipeline/` without `.venv`, tests, bench, `.env` |
| `Contents/Resources/THIRD-PARTY-NOTICES.txt` | `scripts/release/THIRD-PARTY-NOTICES.txt` |
| `Applications` link, `ĐỌC TRƯỚC - Read me first.txt` (Open Anyway steps, vi + en) | `scripts/release/dmg-readme.txt` |

Never in it: `.env`, `HF_TOKEN`, models, recordings, `shared-install.json` (`release.sh` checks and aborts).
Size: ~31 MB (0.1.0).

## Packaged runtime (on the user's Mac)

`~/Library/Application Support/MeetingNotes/runtime/` (`RuntimeLayout`, Core): `pipeline/` (copied from the bundle,
`.venv` inside), `python/`, `bin/uv`, `cache/uv`, `models/{huggingface/hub,fluidaudio}`, `shared-install.json`
(`"mode": "packaged"`) and `setup-state.json`. Setup steps (`SetupMachine`): runtime → speech → diarization →
ollama → summary; each resumable, cancellable, at `nice 10`; paused while recording or a notes job runs. After an
update only the runtime step re-runs (by itself). Uninstall: delete the app and that folder (Ollama models stay
in Ollama). Logs: `~/Library/Logs/MeetingNotes/setup.log`.

## Open before the first public release

- M7 fresh-Mac run (above), including Gatekeeper on the bundled helpers (`MeetingNotesDiarize`, `uv` copied out of
  the bundle has its quarantine flag removed by the app).
- Signing secrets in CI (above), so updates keep permissions.
- Whether to ship an in-app updater (M6).
- CC-BY notices also in Settings › About (today: `THIRD-PARTY-NOTICES.txt` in the bundle).
- Bundle id `com.hoangphu.meetingnotes` vs a company id (switching later resets permissions).
