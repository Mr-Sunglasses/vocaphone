# Contributing

Thanks for helping improve vocaphone. Changes should keep the privacy-first
architecture, the documented network-exposure controls, and the iOS keyboard
constraints intact.

By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
For usage questions and support routing, see [SUPPORT.md](SUPPORT.md). Report
security issues privately via [SECURITY.md](SECURITY.md).

## Ways to contribute

- Report reproducible bugs with the [bug report](.github/ISSUE_TEMPLATE/bug_report.yml) template
- Propose focused improvements with the [feature request](.github/ISSUE_TEMPLATE/feature_request.yml) template
- Improve docs in `README.md` or `docs/`
- Fix bugs or add tests for gateway, iOS, or Android behavior
- Review pull requests for privacy, security, and platform-constraint regressions

Look for issues labeled `good first issue` or `help wanted` when those labels
are available.

Coding-agent instructions (IME frame budget, `InputConnection`, benchmarks)
live in [AGENTS.md](AGENTS.md) and [android/AGENTS.md](android/AGENTS.md).

## Development setup

- Clone with submodules: `git clone --recurse-submodules …` (or
  `git submodule update --init --recursive` on an existing clone). The gateway
  is the [vocagateway](https://github.com/VocaHQ/vocagateway) submodule at
  `gateway/`.
- For iOS, run `just ios fetch` (or `bash ios/ThirdParty/SherpaOnnx/fetch.sh`)
  after cloning. That downloads the pinned sherpa-onnx iOS no-TTS xcframeworks
  from GitHub Releases. They are not stored in git.
- Install [`just`](https://just.systems), Xcode, XcodeGen, `uv`, and FFmpeg.
- For Android work, install a recent Android Studio / SDK and JDK 21 (the exact
  major version matters: F-Droid rebuilds the APK on JDK 21, so reproducible
  builds require the same javac).
- Run `just ios gen` after changing `ios/project.yml`, and commit the
  regenerated project. The other iOS recipes regenerate it for you; this one
  matters because CI fails when the checked-in project is stale.
- Gateway-only changes belong in vocagateway (open the PR there, then bump the
  submodule pin here if this repo needs the new revision).
- Never commit microphone recordings, bearer tokens, signing material, tailnet
  hostnames, local database files, or Apple provisioning profiles.

The shared `ios/VocaPhone.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
file pins WhisperKit and its transitive Swift packages for reproducible iOS
builds. Keep it committed when Swift package dependencies change. Do not
commit Xcode user data under `xcuserdata/`.

Each application owns a justfile, and the repository root aggregates them, so
recipes work from either place:

```sh
just --list              # cross-cutting recipes and the three modules
just --list gateway      # one application's recipes
cd gateway && just test  # same as `just gateway test` from the root
just doctor              # what each application's toolchain is missing
```

`just doctor` is the fastest way to find out what a fresh machine still needs;
it reports all three toolchains and never fails, because nobody has all of them
installed at once.

### Gateway submodule pin (dev vs ship)

The parent repository records a fixed `gateway/` SHA so clones and release builds
are reproducible. That pin is what CI and shipped apps use.

For day-to-day gateway work you can move the **local** checkout to the tip of
`main` without changing what this repo ships:

```sh
just gateway-pin-status  # pin vs working tree vs origin/main
just gateway-sync        # git submodule update --remote gateway (main tip)
just gateway install     # after a sync, if dependencies moved
just gateway run
```

`gateway-sync` only updates your working tree. It does **not** commit a new pin.
When this repo should adopt a newer gateway (or a release tag), do it on purpose:

```sh
just gateway-sync        # or: cd gateway && git fetch --tags && git checkout vX.Y.Z
git add gateway
git commit -m "build: pin vocagateway to <sha or tag>"
```

Phone-only work can leave the recorded pin alone. Shipping builds must never run
`gateway-sync` in CI; they check out the committed pin only.

### direnv (optional)

[direnv](https://direnv.net) is set up but not required; every command in this
repository works without it. With direnv installed, run `direnv allow` once
after cloning. The checked-in `.envrc` then puts the gateway virtualenv and the
Android SDK's `platform-tools` on `PATH`, so `pytest`, `ruff` and `adb` work
without `uv run` or a full path, and exports `ANDROID_HOME`.

Machine-specific settings belong in `.envrc.local`, which is gitignored and
sourced automatically:

```sh
export VOCAPHONE_SIM='iPhone 17 Pro'   # which simulator ios/justfile uses
export ANDROID_SERIAL=emulator-5554    # which device android/justfile targets
```

`.envrc` deliberately does not load `gateway/.env`. That file holds the Compose
bearer token, and the gateway reads `VOCAGATEWAY_TOKEN` straight from the
environment, so exporting it would make a natively run gateway serve the
container's token instead of the one in `~/.config/vocagateway/token` — silently,
because both are valid. Compose reads that file by itself. For the same reason,
only the repository-root `.envrc` is tracked; any nested one is gitignored,
since the quickest way to make `gateway/.envrc` is to copy `gateway/.env` into
it, secret and all.

## Required checks

Each application has one recipe that runs everything its workflow gates on.
Run the one for what you changed:

```sh
just gateway install  # once, and after dependency changes (submodule)
just gateway test     # lint, types, dependency audit, unit tests, Compose
just ios ci           # regenerates the project, builds, runs the unit tests
just android ci       # assembles, unit tests, lint, Room schema freshness
```

`just ci` from the repository root runs all three and skips any whose toolchain
is absent, which is what a contributor with only one platform installed wants.

iOS/Android recipes match the workflows in `.github/workflows/`. Gateway quality
and container CI run in vocagateway; use `just gateway test` / `just gateway image`
against the submodule when you change the pin or work on the gateway itself.

When changing documentation, check local links and commands against the current
repository layout, then run `git diff --check`. Do not publish machine-specific
paths, real tailnet hostnames, tokens, recordings, or transcript samples.

Keyboard, microphone, background-audio, and insertion changes must also be
verified on a physical iPhone — `just ios device` builds and installs onto a
connected phone, and [docs/device-setup.md](docs/device-setup.md) has the
acceptance sequence. Describe the tested app, iOS version, and exact
interaction sequence in the pull request.

For Android changes, note whether the floating bubble was exercised on a
physical device; `just android run` installs and launches on one, and
`just android permissions` grants what the bubble needs.

## Pull requests

- Keep changes focused and document user-visible behavior.
- Add or update tests for state transitions, gateway behavior, and regressions.
- Update README or `docs/` when setup, privacy, security, or architecture changes.
- Do not weaken loopback gateway binding, bearer authentication, upload limits,
  retention, or explicit microphone indicators without discussing the tradeoff.
- Use the pull request template checklist; skip checks that truly do not apply
  and say why.

### On-demand PR builds (`/build`)

Maintainers can comment one of these on a pull request (same idea as VocaMac's
DMG `/build`):

| Comment | Result |
| --- | --- |
| `/build` | Android release APK + iOS ad-hoc IPA (IPA only if signing secrets are set) |
| `/build android` | Android release APK only |
| `/build ios` | iOS ad-hoc IPA only |
| `/build-quick` | Android debug APK only (no release keystore) |

The workflow reacts with a rocket, posts a started note, uploads artifacts, and
replies with download links. Only `OWNER` / `MEMBER` / `COLLABORATOR` comments
trigger it, so fork PRs need a maintainer to run the build.

Android uses the same release keystore as beta tags, so the APK replaces an
installed beta. Install with `adb install -r …` or by opening the APK on the
device.

iOS needs these repository secrets for an IPA (ad-hoc profiles must include the
tester's device UDID):

- `IOS_CERTIFICATE_P12_BASE64`
- `IOS_CERTIFICATE_PASSWORD`
- `IOS_PROVISION_PROFILE_APP_BASE64`
- `IOS_PROVISION_PROFILE_KEYBOARD_BASE64`
- `IOS_PROVISION_PROFILE_LIVEACTIVITY_BASE64`

Without those secrets, `/build` still produces the Android APK and notes that
iOS was skipped. You can also run the workflow manually under Actions → PR Build.

Version tags are platform-prefixed: `android/v0.1.1` publishes Android,
`ios/v1.0.21` uploads iOS to TestFlight. They can share a commit but never a
tag. See [releasing.md](docs/releasing.md).

## Community

[Discord](https://discord.gg/t6muquAJbm) is the fastest place to talk with
maintainers and other people building VocaPhone. Follow
[@vocahq](https://x.com/vocahq) on X for release notes.

## License

Contributions are licensed under the [GNU Affero General Public License v3.0](LICENSE)
(AGPL-3.0), the same license used by
[VocaMac](https://github.com/VocaHQ/vocamac) and
[VocaLinux](https://github.com/VocaHQ/vocalinux) (both AGPL-3.0). By opening a pull
request, you agree that your contribution may be distributed under that license.
