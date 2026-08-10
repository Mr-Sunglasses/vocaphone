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

## Development setup

- Clone with submodules: `git clone --recurse-submodules …` (or
  `git submodule update --init --recursive` on an existing clone). The gateway
  is the [vocagateway](https://github.com/VocaHQ/vocagateway) submodule at
  `server/`.
- Install [Git LFS](https://git-lfs.com/) before cloning and run `git lfs
  install`. After cloning an existing checkout, run `git lfs pull`; this
  downloads the iOS Sherpa ONNX and ONNX Runtime archives that are too large
  for regular Git blobs. `git lfs ls-files` should list the five native
  archives under `ios/ThirdParty/SherpaOnnx/`.
- Install [`just`](https://just.systems), Xcode, XcodeGen, `uv`, and FFmpeg.
- For Android work, install a recent Android Studio / SDK and JDK 17+.
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
just --list server       # one application's recipes
cd server && just test   # same as `just server test` from the root
just doctor              # what each application's toolchain is missing
```

`just doctor` is the fastest way to find out what a fresh machine still needs;
it reports all three toolchains and never fails, because nobody has all of them
installed at once.

### Gateway submodule pin (dev vs ship)

The parent repository records a fixed `server/` SHA so clones and release builds
are reproducible. That pin is what CI and shipped apps use.

For day-to-day gateway work you can move the **local** checkout to the tip of
`main` without changing what this repo ships:

```sh
just server-pin-status   # pin vs working tree vs origin/main
just server-sync         # git submodule update --remote server (main tip)
just server install      # after a sync, if dependencies moved
just server run
```

`server-sync` only updates your working tree. It does **not** commit a new pin.
When this repo should adopt a newer gateway (or a release tag), do it on purpose:

```sh
just server-sync         # or: cd server && git fetch --tags && git checkout vX.Y.Z
git add server
git commit -m "build: pin vocagateway to <sha or tag>"
```

Phone-only work can leave the recorded pin alone. Shipping builds must never run
`server-sync` in CI; they check out the committed pin only.

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

`.envrc` deliberately does not load `server/.env`. That file holds the Compose
bearer token, and the gateway reads `VOCAPHONE_TOKEN` straight from the
environment, so exporting it would make a natively run gateway serve the
container's token instead of the one in `~/.config/vocaphone/token` — silently,
because both are valid. Compose reads that file by itself. For the same reason,
only the repository-root `.envrc` is tracked; any nested one is gitignored,
since the quickest way to make `server/.envrc` is to copy `server/.env` into
it, secret and all.

## Required checks

Each application has one recipe that runs everything its workflow gates on.
Run the one for what you changed:

```sh
just server install   # once, and after dependency changes (submodule)
just server test      # lint, types, dependency audit, unit tests, Compose
just ios ci           # regenerates the project, builds, runs the unit tests
just android ci       # assembles, unit tests, lint, Room schema freshness
```

`just ci` from the repository root runs all three and skips any whose toolchain
is absent, which is what a contributor with only one platform installed wants.

iOS/Android recipes match the workflows in `.github/workflows/`. Gateway quality
and container CI run in vocagateway; use `just server test` / `just server image`
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

## License

Contributions are licensed under the [GNU Affero General Public License v3.0](LICENSE)
(AGPL-3.0), the same family of copyleft license used by
[VocaMac](https://github.com/VocaHQ/vocamac) (AGPL-3.0) and
[VocaLinux](https://github.com/VocaHQ/vocalinux) (GPL-3.0). By opening a pull
request, you agree that your contribution may be distributed under that license.
