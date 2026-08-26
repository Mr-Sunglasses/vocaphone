# AGENTS.md

Instructions for coding agents in this repository.

VocaPhone is a three-toolchain repo: Android (`android/`), iOS (`ios/`), and an
optional self-hosted gateway vendored at `gateway/` (submodule of
[VocaHQ/vocagateway](https://github.com/VocaHQ/vocagateway)). Speech-to-text
runs **on the phone** after a model download, or on a **gateway the user
runs**. There is no Voca cloud transcription product — do not invent one,
do not add a hosted STT API, and do not imply audio leaves the device except
to that optional self-hosted gateway.

User-facing setup and store status live in [README.md](README.md). This file is
the agent contract: worktrees, commands that exist, and what not to commit.

## Critical: git worktrees for every branch and PR

Never create a branch, commit, or open a pull request in the primary checkout. Always use a linked git worktree so the main working tree stays on `main` and stays clean. Do not `git switch` / `git checkout` a feature branch in the primary directory, and do not leave it dirty.

```bash
git fetch origin
git worktree add /tmp/vocaphone-<task> -b <type>/<short-name> origin/main

# All edits, commits, and `gh pr create` happen inside that worktree.

git worktree remove /tmp/vocaphone-<task>
git worktree prune
```

Rules:

- One worktree per branch, one branch per PR
- Place worktrees **outside** the primary working tree (`/tmp/vocaphone-<task>` or a sibling directory such as `../.worktrees/vocaphone-<task>`)
- Never run two tasks in the same worktree
- Never commit directly to `main`
- Clean up the worktree after the PR is pushed

## Clone and toolchain

```bash
# macOS: brew install git-lfs just xcodegen
git lfs install
git clone --recurse-submodules https://github.com/VocaHQ/vocaphone.git
cd vocaphone
git lfs pull
git submodule update --init --recursive
just doctor
```

On an existing clone: `git lfs install && git lfs pull && git submodule update --init --recursive`.

| Need | Why |
| --- | --- |
| `--recurse-submodules` | `gateway/` (vocagateway) and `android/third_party/whisper.cpp` |
| Git LFS | iOS Sherpa/ONNX static archives under `ios/ThirdParty/SherpaOnnx/` (`*.a`). Pointer files will not link |
| JDK **21** exactly | F-Droid rebuilds on 21; reproducible APKs need the same javac. `android/gradle/gradle-daemon-jvm.properties` auto-provisions 21 for Gradle; `just android doctor` checks the JDK on `PATH` |
| Xcode + XcodeGen | iOS. `ios/project.yml` is the project source |
| `uv` + FFmpeg (+ Docker for Compose) | Gateway recipes in the submodule |
| Android SDK, CMake 3.22.1, NDK 27.2.12479018 | Android. `local.properties` / `ANDROID_HOME` |

`just doctor` reports all three legs and **exits 0** even when some are missing.
Each app's own `just <app> doctor` fails when *that* toolchain is incomplete.
Optional [direnv](https://direnv.net): `direnv allow` after clone. Machine-local
values (`VOCAPHONE_SIM`, `ANDROID_SERIAL`) go in gitignored `.envrc.local`. Do
not load `gateway/.env` into the shell (that is the Compose bearer token).

## Layout

| Path | Owns |
| --- | --- |
| `android/` | Kotlin IME, foreground mic service, on-device engines, unit tests. Read [android/AGENTS.md](android/AGENTS.md) before changing the keyboard |
| `ios/` | Swift app, keyboard extension, Live Activity, shared App Group state, tests |
| `gateway/` | Pinned vocagateway checkout (not developed as a first-class tree here) |
| `assets/keyboard/` | Shared word list, bigrams, emoji catalog (both keyboards) |
| `web/` | Static marketing site (vocaphone.vocahq.com) |
| `docs/` | Architecture, privacy, device setup, releasing — not marketing |
| `tools/hinglish/` | Roman Hinglish: the weight-conversion reproduction script and the evaluation harness. Desktop-only; nothing here ships in either app |
| `fdroid/` | F-Droid metadata |
| `telemetry/` | Optional self-hosted Aptabase (usage counters, not STT) |

Root [`justfile`](justfile) aggregates `mod android`, `mod ios`, and optional
`mod? gateway`. Recipes work from the root (`just ios ci`) or inside the app
(`cd ios && just ci`). `gateway/` is optional at parse time so a clone without
the submodule can still run `just`, `just ios …`, `just android …`, and
`just doctor`.

Do not edit `android/third_party/whisper.cpp/` except as an intentional submodule
pin. Ignore its upstream `AGENTS.md`. (`tools/hinglish/convert-apex-ggml.sh`
clones its own copy at the pinned revision and patches that clone; it never
touches the submodule.)

Model weights are never committed. A catalog entry pins a Hugging Face
repository, an immutable revision, and a SHA-256 per file, and the client
verifies the digest as it downloads. A pin that points at a third-party
conversion needs its provenance established rather than assumed — see
[docs/hinglish-roman.md](docs/hinglish-roman.md) for how that was done for the
one entry that has one.

## Commands that exist

```bash
just --list                 # root + modules
just --list android         # one platform
just ci                     # every present toolchain; skips the rest
just doctor
just gateway-pin-status     # recorded pin vs working tree vs origin/main
just gateway-sync           # local gateway/ → .gitmodules branch tip; does not commit
```

| Area | Everyday | Exit gate |
| --- | --- | --- |
| Android | `just android run` · `just android test '*FooTest'` · `just android permissions` · `just android logs` | `just android ci` |
| iOS | `just ios run` · `just ios test VocaPhoneTests/KeyLayoutTests` · `just ios edit` · `just ios device` | `just ios ci` |
| Gateway (submodule checked out, `uv` present) | `just gateway install` · `just gateway run` · `just gateway unit` | `just gateway test` |
| Web | `cd web && npm run check` · `npm run dev` (port 4173) | `npm run check` |
| Brand / emoji | `python3 assets/generate.py --check` · `python3 tools/generate-emoji-catalog.py --check` | same (`just ci` always runs the brand check) |

`just ci` skips a missing Android SDK, non-macOS iOS, missing `uv`, or an
uninitialized gateway; it still fails if a **present** leg fails.

## Gateway submodule

`gateway/` is [VocaHQ/vocagateway](https://github.com/VocaHQ/vocagateway),
branch `main`, recorded as a **fixed SHA** in this repo.

- Gateway-only bugs, features, and CI belong **in vocagateway**. Open the PR
  there. Do not implement gateway server changes as files under this tree.
- Bump the pin here **on purpose** when vocaphone must ship that revision:

  ```bash
  just gateway-sync          # or: cd gateway && git fetch --tags && git checkout vX.Y.Z
  just gateway-pin-status    # confirm working tree vs HEAD:gateway vs origin/main
  git add gateway
  git commit -m "build: pin vocagateway to <sha or tag>"
  ```

- `just gateway-sync` / `git submodule update --remote` **does not commit**.
  Shipping and CI check out the recorded pin only — never run `gateway-sync` in
  this repo's workflows.
- Phone-only work can leave the pin alone.
- After a sync, `just gateway install` if dependencies moved.
- `just gateway test` (in the submodule) is lint, types, lockfile/audit,
  pytest, and `docker compose config`. `just gateway image` builds the
  container locally. Quality and image CI run in vocagateway, not here.

## Android

Develop against the **`full`** flavor (prebuilt sherpa-onnx JNI + whisper.cpp).
**`fdroid`** is whisper.cpp-only, telemetry compiled out, never uploaded to Play.

| Item | Rule |
| --- | --- |
| JDK | 21 (not "17 or newer"). Bytecode target is 17; the *compiling* JDK is 21 |
| Gradle | Wrapper in `android/` (do not introduce a system Gradle) |
| Flavors | Every task names one: `assembleFullDebug`, `testFullDebugUnitTest`, `lintFullDebug` |
| IDs | `applicationId` `com.vocahq.vocaphone`; minSdk 33, compileSdk 37, targetSdk 36 |
| Device | `just android run`; `ANDROID_SERIAL=…` if more than one; `just android permissions` grants mic / notifications / camera |
| Room | Commit `android/app/schemas/` when it changes; `just android ci` fails if stale |
| 16 KB pages | `just android ci` runs `tools/check-page-alignment.py` on the full debug APK |
| Native | whisper.cpp via CMake/NDK from the submodule; do not vendor a second copy |
| Secrets | Never commit `android/local.properties`, `*.keystore`, `*.jks`, `keystore.properties` |

The IME hot path (pointer handling, preview overlay, `InputConnection`
coalescing, dictionary scans, and the 120 Hz benchmark harness) is documented in
[android/AGENTS.md](android/AGENTS.md). Read it before touching
`ime/`. Never load the 10k-word list on the composition thread — not in
production code, and not to make a test pass.

There is **no** `connectedAndroidTest` recipe. Instrumented tests under
`android/app/src/androidTest/` are not a CI gate. Keyboard, bubble, and
microphone changes still need a physical-device note on the PR.

## iOS

`ios/project.yml` is the source of truth. Every iOS recipe runs `xcodegen`
first. After editing `project.yml`, run `just ios gen` and **commit** the
regenerated `VocaPhone.xcodeproj`. Do not hand-edit `project.pbxproj`. CI fails
when the checked-in project is stale.

| Item | Rule |
| --- | --- |
| Toolchain | Xcode (project asks for 26), XcodeGen, iOS 17+, Swift 6. Simulator default `iPhone 17` (`VOCAPHONE_SIM` / `just sim="iPhone 16" run`) |
| Packages | Commit `ios/VocaPhone.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` when Swift deps change |
| User data | Never commit `xcuserdata/` or `*.xcuserstate` |
| LFS | `git lfs pull` before building; missing `.a` files fail the Sherpa link |
| Device | `just ios device` (signing must already work in Xcode). `VOCAPHONE_DEVICE` if several phones |
| Previews | `just ios lint-previews` (`ios/tools/check-preview-isolation.py`). Preview-only code stays behind `#if DEBUG` |
| Signing | Ship identifiers: `com.vocahq.vocaphone` (+ `.keyboard`, `.liveactivity`), App Group `group.com.vocahq`, team `92962VK378`. Personal bundle-id / team edits for a free Apple ID stay local — do not commit them |

The keyboard extension **cannot use the microphone**. The containing app
records; the keyboard shares versioned App Group session state and inserts
through `UITextDocumentProxy`. Full Access is for coordination with the app,
not for recording or keylogging. Do not add mic capture, network calls, or
telemetry to the keyboard target.

## Web and shared assets

`web/` is a dependency-free static site. `npm run check` is the gate
(`.github/workflows/quality-web.yml`). Pages deploy from `main` when `web/`
changes. Pin Android download links to a concrete `android/v*` tag — never
`/releases/latest`.

Keyboard word lists and the emoji catalog live once at `assets/keyboard/`.
iOS references that directory from `project.yml`; Android merges it via
`sourceSets`. Do not fork a second copy. Generated emoji catalog and
suggestion table: `python3 tools/generate-emoji-catalog.py --check` (and
`--write` when regenerating). Brand vectors: edit constants in
`assets/generate.py`, not the output SVGs.

No nested `web/AGENTS.md` — the site has no extra agent rules beyond this.

## Privacy, data, and architecture

Read [docs/privacy.md](docs/privacy.md) and
[docs/architecture.md](docs/architecture.md) before changing audio, tokens,
insertion, or network code.

**Do not commit** (even in fixtures, screenshots, or docs):

- Recordings or transcripts (`*.m4a`, `*.caf`, `*.wav` except the checked-in
  Android cue/test fixtures already allowlisted). This includes the Roman
  Hinglish benchmark audio under `tools/hinglish/benchmark/audio/`, which is
  gitignored and fetched or recorded locally
- Bearer tokens, `gateway/.env`, Keychain dumps
- Signing material: `*.p12`, `*.mobileprovision`, keystores, provisioning profiles
- Tailnet hostnames, personal gateway URLs, LAN IPs of real deployments
- Local DBs (`*.sqlite*`, `gateway/data/`)
- `.env`, `.envrc.local` (root `.envrc` is the only tracked direnv file)

Do not weaken loopback-by-default binding, bearer auth, upload size/duration
limits, success-path audio deletion, or explicit microphone indicators without
an explicit human decision. Usage reporting is **opt-in**, closed-vocabulary
counters to self-hosted Aptabase (`telemetry.vocahq.com`) — not a third-party
analytics SDK and not STT. Telemetry APIs must not grow a free-text parameter.
The iOS keyboard target must not report. The `fdroid` flavor compiles reporting
out.

Report microphone, recording, token, gateway, or tailnet issues via
[SECURITY.md](SECURITY.md), not a public issue.

## Tests and CI

Run the gate for what you changed. Skip the others on the PR template and say
why (docs-only, Linux host, no submodule, …).

| Change | Local | Workflow (path-filtered; drafts skipped until ready) |
| --- | --- | --- |
| `android/**`, `assets/keyboard/**` | `just android ci` | Quality (Android) — JDK 21, recursive submodules, Room schema, 16 KB alignment |
| `ios/**`, `assets/keyboard/**` | `just ios ci` | Quality (iOS) — macOS, Git LFS, stale `xcodeproj`, preview isolation, unit tests |
| `web/**` | `cd web && npm run check` | Quality (web); CodeQL (web) |
| `assets/keyboard/**`, `tools/**` | `python3 tools/generate-emoji-catalog.py --check` | Quality (shared assets) |
| `.github/workflows/**` | — | Lint workflows (`actionlint`) |
| Gateway pin or submodule work | `just gateway test` | vocagateway CI; this repo does not re-run gateway quality |
| Any | `git diff --check` | Semgrep on PRs (non-blocking); CodeQL native is post-merge / weekly, not a PR gate |

Keyboard, microphone, background audio, or insertion: verify on a physical
device (`just ios device` / `just android run`) and describe app, OS, and the
exact sequence in the PR. See [docs/device-setup.md](docs/device-setup.md).

Maintainers may comment `/build`, `/build android`, `/build ios`, or
`/build-quick` for installable artifacts. Agents do not trigger that.

Do not tag releases (`android/v*`, `ios/v*`) or bump store versions unless the
task is a release. See [docs/releasing.md](docs/releasing.md).

## Git, commits, pull requests

- Conventional commits: `feat`, `fix`, `docs`, `ci`, `build`, `chore`, `test`,
  `refactor` — optional scope `android`, `ios`, `web`, `gateway`. Example:
  `docs: add AGENTS.md with mandatory git worktrees`.
- Never push to `main`. Never commit on `main`. Never merge the PR (maintainers
  merge). Never force-push to other people's branches.
- Follow [.github/pull_request_template.md](.github/pull_request_template.md).
  Docs-only: mark `just ios ci` / `just android ci` / device testing N/A and
  say so.
- Stacked PRs: an Android follow-up branches off the open Android PR (for
  example `android/predictive-text`), not off `main`, so review stays stacked.
  If that base is rebased, rebase the follow-up onto it rather than merging.
- Keep the diff focused. Update `docs/` when data flow, permissions, retention,
  or network behavior changes.
- Do not add recordings, tokens, tailnet names, or signing files to "make CI
  pass."

## Out of scope unless asked

- Inventing a Voca-hosted speech cloud, relay, or "Voca API" for audio
- Editing upstream `whisper.cpp` or vocagateway *as if they were this repo*
- Changing bundle IDs, App Group, or `DEVELOPMENT_TEAM` in a contributor PR
- Play / TestFlight listing, keystore, or App Store Connect API key work
- Merging, tagging, or pushing to `main`
