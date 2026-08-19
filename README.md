<div align="center">

<img src="assets/vocaphone-logo-512.png" alt="" width="120" height="120">

# VocaPhone

**Voice dictation for iPhone and Android.**

<!-- Product -->
[![Status: Android beta / iOS source](https://img.shields.io/badge/status-Android%20beta%20%2F%20iOS%20source-yellow)](#status)
[![Privacy: on-device / optional gateway](https://img.shields.io/badge/privacy-on--device%20%2F%20optional%20gateway-success)](#privacy-and-platform-boundaries)
[![Release](https://img.shields.io/github/v/release/VocaHQ/vocaphone?include_prereleases)](https://github.com/VocaHQ/vocaphone/releases/latest)
[![vocaphone.vocahq.com](https://img.shields.io/badge/site-vocaphone.vocahq.com-0F6B57)](https://vocaphone.vocahq.com)
<br>

<!-- Family / community -->
[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-blue.svg)](LICENSE)
[![Discord](https://img.shields.io/discord/1538633755877580810?logo=discord&logoColor=white&label=Discord)](https://discord.gg/UMJduhcqn)
[![X](https://img.shields.io/badge/X-vocahq-black?logo=x&logoColor=white)](https://x.com/vocahq)
[![VocaHQ](https://img.shields.io/badge/VocaHQ-vocahq.com-0F6B57)](https://vocahq.com)

Speak into your phone. Text shows up where you're typing. Speech-to-text runs
on your phone by default, or on optional self-hosted VocaGateway, and never on
a cloud speech service.

</div>

---

VocaPhone is the phone side of the [Voca](https://github.com/VocaHQ) family,
next to [VocaLinux](https://github.com/VocaHQ/vocalinux),
[VocaMac](https://github.com/VocaHQ/vocamac), and
[VocaWin](https://github.com/VocaHQ/vocawin). VocaWin is an unsigned
developer alpha on [GitHub Releases](https://github.com/VocaHQ/vocawin/releases).

Licensed under [AGPL-3.0](LICENSE): free to use, study, modify, and share, with
copyleft that also covers modified versions offered as a network service.

## Status

| Client | State |
| --- | --- |
| **Android** | Public beta for Android 13+. [releases](https://github.com/VocaHQ/vocaphone/releases) · [vocaphone.vocahq.com](https://vocaphone.vocahq.com) |
| **iOS** | Build from source for iOS 17+ (Mac, Xcode, signing team, physical iPhone) · [iPhone guide](https://vocaphone.vocahq.com/iphone/) |
| **Gateway** | Optional. Self-host [VocaGateway](https://github.com/VocaHQ/vocagateway) on macOS/Linux or Docker when you want more models or shared compute |

## How it works

On iPhone, VocaPhone is a custom keyboard plus a containing app. On Android it
is a normal system keyboard: select it when you want to dictate. Both insert at
the cursor (iOS through `UITextDocumentProxy`, Android through
`InputConnection`) with the same styles and transcription choices.

Both clients can run speech-to-text on the phone after a model download, or send
recoverable audio to optional VocaGateway. Either way, the transcript inserts at
the active cursor. A gateway is never required for on-device mode.

> [!IMPORTANT]
> iOS keyboard extensions cannot access the microphone. VocaPhone records in
> the containing app, shares only versioned session state with the keyboard, and
> then inserts through `UITextDocumentProxy`. Quick Dictation can keep that app
> ready for up to 10 minutes so most later dictations do not require another app
> switch. The speech-to-text model still runs on the iPhone in on-device mode.

## Highlights

- The keyboard inserts the transcript at the cursor in the field you are already using
- After you download a speech-to-text model, on-device dictation needs no gateway
- Optional VocaGateway runs on a Mac, Linux box, or home server you control when
  you want larger models or shared compute. That path is self-hosted, not on-device
- 27 transcription languages plus Automatic, and four writing styles: Formal,
  Casual, Very Casual, and Excited
- On iOS the containing app records, because a keyboard extension cannot use the
  microphone

## Part of Voca

| Platform | Project | Repo | Status |
| --- | --- | --- | --- |
| Linux | VocaLinux | [VocaHQ/vocalinux](https://github.com/VocaHQ/vocalinux) | Available now |
| macOS | VocaMac | [VocaHQ/vocamac](https://github.com/VocaHQ/vocamac) | Beta |
| Windows | VocaWin | [VocaHQ/vocawin](https://github.com/VocaHQ/vocawin) | Developer alpha · [releases](https://github.com/VocaHQ/vocawin/releases) |
| iOS / Android | VocaPhone | [VocaHQ/vocaphone](https://github.com/VocaHQ/vocaphone) | Android beta / iOS source build · [site](https://vocaphone.vocahq.com) |

Org: [github.com/VocaHQ](https://github.com/VocaHQ). Contact:
[hello@vocahq.com](mailto:hello@vocahq.com)

## Quick start

### 1. Android (public beta)

Public beta APKs for Android 13+ are on
[GitHub Releases](https://github.com/VocaHQ/vocaphone/releases). Install one,
enable VocaPhone in Android's keyboard settings, grant microphone (and
notifications if asked), then download an on-device speech-to-text model.

To build from source:

```sh
cd android
# macOS default; on Linux try $HOME/Android/Sdk
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
# "full" is the flavor to develop against; "fdroid" is the from-source-only
# build described under Build flavors in android/README.md.
./gradlew assembleFullDebug
# Uninstall any pre-rename Local Flow build first. Application IDs differ, so
# `adb install -r` will side-install next to io.github.mrsunglasses.localflow.
adb uninstall io.github.mrsunglasses.localflow 2>/dev/null || true
adb install -r app/build/outputs/apk/full/debug/vocaphone-fullDebug.apk
```

See the [Android client guide](android/README.md) for keyboard setup and the
supported gateway address forms.

### 2. iOS (source)

The Simulator needs no Apple account at all:

```sh
cd ios
just doctor   # checks Xcode, xcodegen, and a simulator runtime are present
just run      # generates the project, builds, boots a simulator, installs, launches
```

`ios/project.yml` is the real project source; `just run` (and every other iOS
recipe) regenerates `VocaPhone.xcodeproj` from it before building, so don't
hand-edit the `.xcodeproj`. Prefer working in Xcode itself? `just edit` does
the same regeneration, then opens it.

Add the keyboard the same way you would on a device: `just settings` opens
iOS Settings on the simulator, then **General → Keyboard → Keyboards → Add
New Keyboard → vocaphone**, with **Allow Full Access** turned on (see
[privacy.md](docs/privacy.md#full-access) for exactly what that is and isn't
used for). Typing, autocorrect, and swipe work immediately. For actual
dictation, **Settings → Transcription → On this iPhone** plus a downloaded
model is the fastest path with nothing else to configure, or point
**Settings → Transcription → Gateway** at an optional VocaGateway.

**On your own iPhone** (`just device`, phone connected and trusted): code
signing has to already work in Xcode first. The project ships with VocaHQ's
own identifiers (`com.vocahq.vocaphone` and friends, team `92962VK378`; see
[decisions.md](docs/decisions.md)). If you have access to that team, select
it on all three targets (VocaPhoneApp, VocaPhoneKeyboard,
VocaPhoneLiveActivity) under **Signing & Capabilities**; automatic signing
does the rest. If you don't (most outside contributors), either ask a
maintainer to comment `/build ios` on your pull request for a signed ad-hoc
IPA (see [CONTRIBUTING.md](CONTRIBUTING.md#on-demand-pr-builds-build)), or run
it under your own free Apple ID by changing `bundleIdPrefix` and the three
`PRODUCT_BUNDLE_IDENTIFIER`s in `ios/project.yml`, the App Group string in all
three `.entitlements` files, and `AppConfiguration.swift`'s
`appGroupIdentifier`/`keyboardBundleIdentifier`. Don't commit that change.

Grant microphone access on first launch, add the keyboard as above, and turn
on Full Access. Complete the physical-device checklist in [device
setup](docs/device-setup.md).

iOS Sherpa ONNX archives are Git LFS objects, and the gateway checkout is a
submodule. Clone with both before you build:

```sh
# macOS: brew install git-lfs; other platforms: https://git-lfs.com/
git lfs install
git clone --recurse-submodules https://github.com/VocaHQ/vocaphone.git
cd vocaphone
git lfs pull
git submodule update --init --recursive
```

On an existing clone: `git lfs install && git lfs pull && git submodule update --init --recursive`.
Without Git LFS those framework paths are pointer files and the iOS project
cannot link the on-device engine. Pin bumps live in
[CONTRIBUTING.md](CONTRIBUTING.md#gateway-submodule-pin-dev-vs-ship).

### 3. Optional gateway

On-device mode needs no gateway. When you want larger models or shared compute,
self-host [VocaGateway](https://github.com/VocaHQ/vocagateway) and point the
phone at it. Native vs Docker, pairing, and how the phone reaches the host are
in that repository and in [docs/deployment.md](docs/deployment.md).

## Build and test

Development uses [`just`](https://just.systems). Each application has a
justfile, and the repository root aggregates them, so every recipe works from
the root or from inside the application directory:

```sh
just ci               # all three applications, skipping absent toolchains
just gateway test     # gateway: lint, types, dependency audit, tests, Compose
just gateway-sync     # optional: local gateway/ → tip of main (does not commit)
just gateway-pin-status
just ios ci           # iOS: regenerate the project, build, run unit tests
just android ci       # Android: assemble, unit tests, lint, Room schema
just doctor           # what each toolchain is still missing
```

iOS and Android CI live in this repository. Gateway quality and container
builds run in [vocagateway](https://github.com/VocaHQ/vocagateway); `just gateway
test` still exercises the submodule checkout locally. `just --list` shows the
rest, including running the apps (`just ios run`, `just android run`,
`just gateway run`), streaming logs, installing onto a physical phone, and
managing the container deployment.

Optional: with [direnv](https://direnv.net) installed, `direnv allow` once after
cloning puts the gateway virtualenv and the Android SDK's `platform-tools` on
`PATH` and exports `ANDROID_HOME`, so `pytest` and `adb` resolve without a
prefix or a full path. Everything works without it. See
[CONTRIBUTING.md](CONTRIBUTING.md#direnv-optional).

The generated Xcode project is checked in. Run `just ios gen` after changing
`ios/project.yml` and commit the result; CI fails when it is stale. Keyboard,
microphone, background audio, and insertion changes still require
physical-device verification.

## Project layout

```text
ios/                    Swift app, keyboard, Live Activity, shared state, tests
android/                Kotlin app, voice keyboard, foreground dictation service, tests
gateway/                Git submodule → VocaHQ/vocagateway (gateway + WebUI)
docs/                   Architecture, device setup, privacy, decisions, historical plans
```

## Documentation

| Guide | Covers |
| --- | --- |
| [Android client](android/README.md) | Building the APK, guided setup, voice keyboard, and privacy boundaries |
| [Gateway reference](gateway/README.md) | Native service, Compose, models, configuration, health, and CLI commands ([vocagateway](https://github.com/VocaHQ/vocagateway)) |
| [Deployment](docs/deployment.md) | Pointers into vocagateway for native vs Docker, pairing, and host setup |
| [Device setup](docs/device-setup.md) | Apple signing, keyboard installation, and physical-device acceptance |
| [TestFlight](docs/testflight.md) | App Store Connect setup, archiving, and TestFlight distribution |
| [Google Play prep](docs/play-store.md) | Full-flavor AAB, upload signing, listing and Console checklist |
| [Tailscale](docs/tailscale.md) | Private HTTPS ingress for the gateway |
| [Architecture](docs/architecture.md) | Components, state transitions, engine boundary, and observability |
| [Privacy](docs/privacy.md) | Audio lifecycle, authentication, metrics, and threat model |
| [Troubleshooting](docs/troubleshooting.md) | Keyboard, microphone, model, network, and Docker failures |
| [Decisions](docs/decisions.md) | Current assumptions and choices still requiring confirmation |
| [iOS plan](docs/Plan.md) | Original iOS implementation plan and acceptance criteria |
| [Android plan](docs/Plan-Android.md) | Original Android implementation plan and acceptance criteria |
| [Contributing](CONTRIBUTING.md) | Development workflow and required checks |
| [Security](SECURITY.md) | Private vulnerability-reporting process |

## Privacy and platform boundaries

- The iOS keyboard never records audio; Android's IME delegates capture to the
  microphone foreground service and never uses clipboard insertion.
- Quick Dictation standby buffers are discarded rather than saved or uploaded.
- Successful audio is deleted by default; failed sessions expire after the
  configured retry window.
- Operational metrics contain counts and timings only and reset when the gateway
  restarts.
- iOS does not provide a public API to reopen an arbitrary previously active app.
  If Quick Dictation expires, the containing app must open and the user returns
  manually.
- Secure fields and apps that disable third-party keyboards remain iOS platform
  limitations.
- On Android, the VocaPhone keyboard inserts through `InputConnection` and does
  not read surrounding field contents. Sensitive input types disable dictation.

## Contributing, support, security, and license

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, required checks, and pull
request expectations. [SUPPORT.md](SUPPORT.md) is where to ask for help and what
to include (or omit). [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) is Contributor
Covenant 2.1. [SECURITY.md](SECURITY.md) is the private vulnerability-reporting
process.

Report suspected microphone, recording, token, gateway, or tailnet
vulnerabilities through the private process in [SECURITY.md](SECURITY.md), not a
public issue.

### License

VocaPhone is licensed under the **GNU Affero General Public License v3.0**
([AGPL-3.0](LICENSE)), matching [VocaMac](https://github.com/VocaHQ/vocamac) and
[VocaLinux](https://github.com/VocaHQ/vocalinux) (both AGPL-3.0).

You may use, study, modify, and redistribute the software under AGPL-3.0. Because
VocaPhone includes an optional network gateway, AGPL also requires that modified
versions offered as a network service make their corresponding source available.
