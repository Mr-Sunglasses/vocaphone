<div align="center">

<img src="assets/vocaphone-logo-512.png" alt="" width="120" height="120">

# vocaphone

**Voice dictation for iPhone and Android.**

[![Status: in development](https://img.shields.io/badge/status-in%20development-yellow)](#status)
[![Platform: iOS + Android](https://img.shields.io/badge/platform-iOS%20%2B%20Android-lightgrey)](#how-it-works)
[![Privacy: self-hosted](https://img.shields.io/badge/privacy-self--hosted%20%2F%20no%20cloud%20STT-success)](#privacy-and-platform-boundaries)
[![Part of VocaHQ](https://img.shields.io/badge/family-VocaHQ-1a7f4e)](https://github.com/VocaHQ)
[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-blue.svg)](LICENSE)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)
[![Contributing](https://img.shields.io/badge/guide-contributing-informational)](CONTRIBUTING.md)
[![Support](https://img.shields.io/badge/guide-support-informational)](SUPPORT.md)
[![Code of Conduct](https://img.shields.io/badge/contributor%20covenant-2.1-4baaaa.svg)](CODE_OF_CONDUCT.md)
[![Security policy](https://img.shields.io/badge/security-policy-red.svg)](SECURITY.md)
[![GitHub Issues](https://img.shields.io/github/issues/VocaHQ/vocaphone)](https://github.com/VocaHQ/vocaphone/issues)

Speak into your phone. Text shows up where you're typing. Transcription runs on
hardware you control, not a cloud speech service.

</div>

---

**vocaphone** is the phone side of the [Voca](https://github.com/VocaHQ) family:
the same privacy-first dictation idea that already runs on Linux
([VocaLinux](https://github.com/VocaHQ/vocalinux)) and macOS
([VocaMac](https://github.com/VocaHQ/vocamac)), with Windows coming later.

Longer term the goal is straightforward: set Voca up once and use it across
whatever machines you own. Desktop plus phone is what makes that real.

Dictate from an iPhone or VocaPhone Android keyboard. Audio goes to a
gateway on your Mac, Linux box, or home server. Local speech models turn it into
text, and the transcript lands at your cursor. No accounts, no cloud STT, and no
subscription.

## Status

| Client | State |
| --- | --- |
| **iOS** | End-to-end flow exercised on a physical iPhone 14 Pro: keyboard handoff, background recording, private Tailscale transcription, direct insertion |
| **Android** | IME-only release path builds, passes unit tests/lint, and has been installed and selected on a physical Android device |
| **Gateway** | Runs natively on macOS/Linux or via Docker Compose, with multiple local engine adapters |

Licensed under [AGPL-3.0](LICENSE): free to use, study, modify, and share, with
copyleft that also covers modified versions offered as a network service.

## How it works

On iPhone, vocaphone is a custom keyboard plus a containing app. iOS keyboard
extensions cannot access the microphone, so the app records, shares only
versioned session state with the keyboard, and inserts through
`UITextDocumentProxy`. Quick Dictation can keep the app ready for up to 10
minutes so most later dictations skip another app switch.

On Android, VocaPhone is a normal system keyboard. Select it when you want to
dictate; it inserts through Android's `InputConnection` with the same styles and
gateway as iOS.

Both clients send recoverable audio to the same private gateway and insert the
final transcript at the active cursor.

> [!IMPORTANT]
> iOS keyboard extensions cannot access the microphone. vocaphone records in
> the containing app, shares only versioned session state with the keyboard, and
> then inserts through `UITextDocumentProxy`. Quick Dictation can keep that app
> ready for up to 10 minutes so most later dictations do not require another app
> switch.

## Why vocaphone

Most phone dictation means either a cloud API listening to every utterance, or
an app that only works inside itself. vocaphone is built differently.

Transcription runs on a Mac, Linux desktop, or home server you already own, not
a vendor's GPU farm. You pick the network path: trusted LAN, private Tailscale,
or HTTPS behind your own reverse proxy. Bearer tokens are per device. There is
no analytics SDK and no third-party transcription.

Same privacy stance as VocaLinux and VocaMac: free, offline first, and meant to
stay that way. We also document the awkward platform bits honestly: iOS keyboard
limits and Android's keyboard/input-method boundaries.

## Highlights

- Native SwiftUI app and UIKit keyboard with Start, Finish, Cancel, Retry, Undo,
  language/style status, next-keyboard control, and direct insertion
- A full four-row QWERTY keyboard with letters, numbers and symbols planes,
  long-press accented characters, delete-repeat, double-space period, spacebar
  cursor control, and a Compact/Standard/Tall height preference
- On-device word completion, autocorrect and next-word prediction on iOS, worked
  out by the system dictionary plus your own words — nothing typed is sent
  anywhere, logged, or exported, and it all works with Full Access off
- Swipe typing, an emoji panel with local search, and smart punctuation that
  honours what the field asks for, on both clients
- Every surface states where speech becomes text — "Transcribing on this iPhone"
  or "Transcribing on your gateway" — in the keyboard, the app, and the Live
  Activity, and stays neutral rather than guessing when a session predates the
  choice
- Native Kotlin/Compose Android client with a permission-minimal VocaPhone voice
  keyboard, the same styles and gateway as the iOS keyboard
- 27 selectable transcription languages plus Automatic on both clients —
  English, Mandarin Chinese, Spanish, French, German, Russian, Portuguese,
  Italian, Dutch, Polish, Ukrainian, Arabic, Japanese, Korean and Vietnamese,
  along with Hindi, Bengali, Tamil, Telugu, Marathi, Gujarati, Urdu, Kannada,
  Malayalam, Punjabi, Assamese and Nepali — and four writing styles: Formal,
  Casual, Very Casual, and Excited, with sentence punctuation that follows the
  script rather than assuming a Latin full stop
- Automatic microphone routing or an explicit Microphone preference,
  with the input currently in use shown in the app
- A bounded Quick Dictation window with persistent background input, a Live
  Activity/Dynamic Island timer, and standby buffers that are discarded
- FastAPI gateway with bounded uploads, SQLite idempotency, FFmpeg normalization,
  silence detection, retention cleanup, and stable error responses
- VocaMac, Handy, WhisperKit, Apple-native MLX Audio, persistent `sherpa-onnx`
  and `faster-whisper`, multilingual Moonshine, and `whisper.cpp` adapters.
  The VocaMac and Handy desktop apps are optional, Mac-only, and reuse the
  models they already downloaded
- A 58-model catalog spanning Whisper, Parakeet, SenseVoice, Moonshine, GigaAM,
  Canary, Qwen3-ASR, Granite Speech, and Dolphin (40 Eastern
  languages, including Hindi, Bengali, Tamil and Urdu), filterable by the
  language you actually speak
- Operational dashboard with hardware detection, queue/outcome counters,
  pipeline benchmarks, real-time factor, peak memory, and warmup state
- CPU/OpenBLAS, host-native CPU, NVIDIA CUDA, and Vulkan Compose profiles
- Bearer authentication with named per-device tokens and revocation, iOS
  Keychain storage, configurable HTTP/HTTPS gateway access, optional private
  Tailscale HTTPS, no analytics, and no third-party transcription

## Part of VocaHQ

| Platform | Project | Repo | Status |
| --- | --- | --- | --- |
| Linux | VocaLinux | [VocaHQ/vocalinux](https://github.com/VocaHQ/vocalinux) | Stable |
| macOS | VocaMac | [VocaHQ/vocamac](https://github.com/VocaHQ/vocamac) | Beta |
| Windows | VocaWin | [VocaHQ/vocawin](https://github.com/VocaHQ/vocawin) | Coming soon |
| iOS / Android | vocaphone | [VocaHQ/vocaphone](https://github.com/VocaHQ/vocaphone) | In development |

Org: [github.com/VocaHQ](https://github.com/VocaHQ). Contact:
[hello@vocahq.com](mailto:hello@vocahq.com)

## Choose a gateway deployment

| Deployment | Best for | Speech engine | Expected performance |
| --- | --- | --- | --- |
| Native macOS | Daily use on an Apple silicon Mac | MLX Audio, WhisperKit, VocaMac, Handy, sherpa-onnx | Best with Apple-native MLX/Core ML engines |
| Native Linux | Daily use on a Linux desktop or home server | sherpa-onnx INT8, faster-whisper, Moonshine | Good CPU latency; optional CUDA/Vulkan via Docker profiles |
| Docker Compose | Reproducible Linux images and multi-arch hosts | sherpa-onnx INT8, faster-whisper INT8, Moonshine, or accelerated `whisper.cpp` | Portable CPU by default; optional native/CUDA/Vulkan profiles |

On an Apple silicon Mac, use the native gateway for the lowest virtualization
overhead. MLX Audio runs directly on M-series unified memory/GPU, while
WhisperKit uses Core ML; the gateway keeps either selected model resident between
dictations. The container deliberately uses portable Linux runtimes and cannot
use macOS MLX or Core ML from inside Docker Desktop.

On Linux, prefer the native gateway when you already have Python 3.12+ and FFmpeg
on the host. Use Docker when you want an isolated image, CUDA/Vulkan profiles, or
a multi-architecture registry build. Precise speed depends on the model, audio
duration, and hardware; compare the same recording and model class before drawing
benchmark conclusions.

See [deployment choices](docs/deployment.md) for the complete comparison and
operational commands.

## Repository layout note

The headless gateway lives in [VocaHQ/vocagateway](https://github.com/VocaHQ/vocagateway)
and is vendored here as the `server/` git submodule so the phone clients and
future desktop apps share one implementation. The iOS Sherpa ONNX and ONNX
Runtime archives are tracked with Git LFS, so install Git LFS before cloning.
Clone with submodules and LFS:

```sh
# macOS: brew install git-lfs; other platforms: https://git-lfs.com/
git lfs install
# new clone:
git clone --recurse-submodules https://github.com/VocaHQ/vocaphone.git
cd vocaphone
git lfs pull
git submodule update --init --recursive
```

For an existing clone, run these commands from the repository root:

```sh
git lfs install
git lfs pull
git submodule update --init --recursive
```

Without Git LFS, those framework paths contain small pointer files instead of
the native archives and the iOS project cannot link its local model engine.
This repository records a fixed gateway commit (the pin) for reproducible
clones and releases. For local development you can follow `main` without
shipping that tip until you intentionally bump the pin:

```sh
just server-pin-status   # pin vs working tree vs origin/main
just server-sync         # move server/ to the tip of main (local only)
```

Gateway CI, releases, and deep ops docs run in the vocagateway repository.
Phone-side docs below still use `cd server` against the submodule checkout.
See [CONTRIBUTING.md](CONTRIBUTING.md#gateway-submodule-pin-dev-vs-ship) for pin
bumps and release tags.

## Quick start

### 1. Start the gateway natively on macOS

Install the tools (FFmpeg, plus the WhisperKit and `whisper.cpp` CLIs) and
launch the server:

```sh
brew install ffmpeg whisperkit-cli whisper-cpp
cd server
uv sync --all-groups --extra engines --extra apple
uv run vocaphone-server
```

The first run creates a private bearer token at
`~/.config/vocaphone/token`. Open `http://127.0.0.1:8765/`, enter that token,
download a recommended model from **Models**, select it, and confirm the Overview
shows **Ready for dictation**.

To keep the gateway running after the terminal closes and restart it after login:

```sh
cd server
./scripts/install-launch-agent.sh
```

### 2. Or start the gateway natively on Linux

Requires Python 3.12+, [uv](https://docs.astral.sh/uv/), and FFmpeg. On Debian or
Ubuntu:

```sh
sudo apt install ffmpeg
# Install uv if needed: curl -LsSf https://astral.sh/uv/install.sh | sh
cd server
uv sync --all-groups --extra engines
uv run vocaphone-server
```

Omit the `apple` extra on Linux; MLX Audio and WhisperKit are macOS-only. The
startup banner prints the WebUI URL and where the bearer token lives:

```text
vocaphone gateway listening on 0.0.0.0:8765
WebUI (this host): http://127.0.0.1:8765/
Network access: use this host's LAN or Tailscale IP with the same port
Token: ~/.config/vocaphone/token
  (cat ~/.config/vocaphone/token — enter that value in the phone app)
  or: just token  (prints a terminal QR for headless phone pairing)
```

Open the WebUI, enter the token from `~/.config/vocaphone/token`, download a
recommended model (SenseVoice Small INT8 or Parakeet TDT INT8 on CPU), select it,
and confirm Overview shows **Ready for dictation**. For headless phone pairing
without the WebUI, run `just token` (or `just server token` from the repo root)
on a TTY to print a scannable pairing QR.

To keep the gateway running after the terminal closes (systemd user unit):

```sh
cd server
./scripts/install-systemd-user.sh
# optional: survive logout
loginctl enable-linger "$USER"
```

Logs: `journalctl --user -u com.vocahq.vocaphone.gateway.service -f`.

### 3. Or start it with Docker Compose

The canonical Compose file is [server/compose.yaml](server/compose.yaml). It
publishes the gateway only on host loopback by default and stores models,
configuration, and the session database in a named volume.

```sh
cd server
umask 077
printf 'VOCAPHONE_TOKEN=%s\n' "$(openssl rand -hex 32)" > .env
printf 'VOCAPHONE_PUBLISH_HOST=127.0.0.1\n' >> .env
printf 'VOCAPHONE_PUBLISH_PORT=8765\n' >> .env
docker compose up --detach --build
docker compose ps
curl --fail http://127.0.0.1:8765/health/live
```

Open the WebUI, enter the token from `server/.env`, and download/select a
recommended sherpa-onnx, Moonshine, or faster-whisper model. Readiness returns
`503` until a runnable model is selected:

```sh
curl --fail http://127.0.0.1:8765/health/ready
```

Copy [server/.env.example](server/.env.example) if you prefer an editable
template. Never commit the resulting `.env` file.

### 4. Choose how the phone reaches the gateway

The iPhone and Android apps accept any valid `http://` or `https://` gateway URL.
Choose one of these network arrangements:

- **Trusted LAN:** the native gateway listens on all interfaces by default. On
  the same Wi‑Fi, enter `http://<host-lan-ip>:8765` (for example
  `http://192.168.1.75:8765`). Find the IP with `hostname -I` or
  `ip -4 addr`. HTTP is unencrypted, so use this only on a network you trust and
  never forward that port to the internet. For Docker, set
  `VOCAPHONE_PUBLISH_HOST=0.0.0.0` in `server/.env` and protect the port with the
  host firewall. The container's own address auto-discovery (used by the
  pairing QR) can't see the host's LAN IP under the default bridge network
  either; on Linux Docker Engine, set `VOCAPHONE_NETWORK_MODE=host` in
  `server/.env` instead so discovery finds it directly — see
  [server/README.md](server/README.md#configuration).
- **Tailscale:** keep the gateway on loopback and let Tailscale Serve provide
  tailnet-only HTTPS:

```sh
# optional: bind loopback only when using Serve
# VOCAPHONE_BIND_HOST=127.0.0.1 uv run vocaphone-server
tailscale serve --bg 8765
tailscale serve status
```

- **VPS or public DNS:** put the loopback gateway behind an HTTPS reverse proxy
  with a trusted certificate and enter a URL such as
  `https://dictation.example.com/`. Do not send recordings or bearer tokens over
  public HTTP.

### Pair the phone with a QR code (iPhone or Android)

**Without the WebUI (headless):** on the gateway host, run `just token` (or
`just server token` from the repo root). On a TTY it prints an ASCII QR that
encodes the same pairing payload as the WebUI. Point the phone's camera at the
terminal, or use `just token --plain` / `cat ~/.config/vocaphone/token` when you
only need the secret.

**From the WebUI:** once authenticated on the gateway host:

1. Stay on **Overview** — the **Pair phone app** card shows a QR for a
   phone-reachable address (LAN IP preferred, or `VOCAPHONE_PUBLIC_URL` if set).
2. To give this phone its own revocable credential instead of the shared
   bootstrap token, use **Or pair a new device with its own token**: name the
   device and the card immediately shows a QR for that device's token alone.
   The **Token to encode** dropdown switches the QR between the bootstrap
   token and any device token created this way; manage or revoke them later
   from Settings → **Paired device tokens**.
3. In the iPhone app, open **Settings → Transcription → Gateway** and tap
   **Scan pairing QR code**. On Android, open **Gateway** and tap
   **Scan QR code**.
4. Grant camera access if asked; the scan fills address + token and runs the
   connection test.

You can still paste manually:

1. **Gateway address** — the LAN, Tailscale, or HTTPS URL above.
2. **Bearer token** — `just token --plain` or `cat ~/.config/vocaphone/token`
   for native installs, or the `VOCAPHONE_TOKEN` value from `server/.env` for
   Docker.

Then use **Save and test** / **Test connection**. Tailscale is recommended for a
private personal deployment, but it is not mandatory. Follow
[deployment](docs/deployment.md) and the optional
[Tailscale guide](docs/tailscale.md) for the relevant host configuration.

### 5. Configure and install the iPhone app

Before signing under your own Apple account, replace these placeholders
consistently in the Xcode project configuration and entitlements:

- `com.vocahq.vocaphone`
- `com.vocahq.vocaphone.keyboard`
- `com.vocahq.vocaphone.liveactivity`
- `group.com.vocahq.vocaphone`

Then:

1. Generate/open `ios/VocaPhone.xcodeproj` and select your Apple development team.
2. Register the same App Group for the app, keyboard, and Live Activity targets.
3. Install the containing app on the iPhone and grant microphone permission.
4. Add the keyboard under **Settings → General → Keyboard → Keyboards** and enable
   Full Access.
5. Choose a transcription source in guided setup: download an on-device
   speech-to-text model, **or** enter the reachable HTTP/HTTPS gateway URL and
   bearer token under **Settings → Transcription → Gateway** and use
   **Save and test**. Approve Local Network access when using a LAN host.
   Either source alone is enough to dictate; the app says which one is in use
   and where the audio goes.

Complete the physical-device checklist in [device setup](docs/device-setup.md).

### 6. Or install the Android app

Android adds VocaPhone as a selectable voice keyboard. Build and install the APK,
then follow the guided setup in the app:

```sh
cd android
# macOS default; on Linux try $HOME/Android/Sdk
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
# "full" is the flavor to develop against; "fdroid" is the from-source-only
# build described under Build flavors below.
./gradlew assembleFullDebug
# Uninstall any pre-rename Local Flow build first — application IDs differ, so
# `adb install -r` will side-install next to io.github.mrsunglasses.localflow.
adb uninstall io.github.mrsunglasses.localflow 2>/dev/null || true
adb install -r app/build/outputs/apk/full/debug/vocaphone-fullDebug.apk
```

In the app: grant microphone and notifications, enable and select VocaPhone in
Android's keyboard settings, then enter the gateway address and bearer token from
step 4 and run **Test connection**.

See the [Android client guide](android/README.md) for keyboard setup and the
supported gateway address forms.

## Build and test

Development uses [`just`](https://just.systems). Each application has a
justfile, and the repository root aggregates them, so every recipe works from
the root or from inside the application directory:

```sh
just ci               # all three applications, skipping absent toolchains
just server test      # gateway: lint, types, dependency audit, tests, Compose
just server-sync      # optional: local server/ → tip of main (does not commit)
just server-pin-status
just ios ci           # iOS: regenerate the project, build, run unit tests
just android ci       # Android: assemble, unit tests, lint, Room schema
just doctor           # what each toolchain is still missing
```

iOS and Android CI live in this repository. Gateway quality and container
builds run in [vocagateway](https://github.com/VocaHQ/vocagateway); `just server
test` still exercises the submodule checkout locally. `just --list` shows the
rest — running the
apps (`just ios run`,
`just android run`, `just server run`), streaming logs, installing onto a
physical phone, and managing the container deployment.

Optional: with [direnv](https://direnv.net) installed, `direnv allow` once after
cloning puts the gateway virtualenv and the Android SDK's `platform-tools` on
`PATH` and exports `ANDROID_HOME`, so `pytest` and `adb` resolve without a
prefix or a full path. Everything works without it — see
[CONTRIBUTING.md](CONTRIBUTING.md#direnv-optional).

The generated Xcode project is checked in. Run `just ios gen` after changing
`ios/project.yml` and commit the result; CI fails when it is stale. Keyboard,
microphone, background audio, and insertion changes still require
physical-device verification.

## Project layout

```text
ios/                    Swift app, keyboard, Live Activity, shared state, tests
android/                Kotlin app, voice keyboard, foreground dictation service, tests
server/                 Git submodule → VocaHQ/vocagateway (gateway + WebUI)
docs/                   Architecture, device setup, privacy, decisions, historical plans
```

## Documentation

| Guide | Covers |
| --- | --- |
| [Android client](android/README.md) | Building the APK, guided setup, voice keyboard, and privacy boundaries |
| [Gateway reference](server/README.md) | Native service, Compose, models, configuration, health, and CLI commands ([vocagateway](https://github.com/VocaHQ/vocagateway)) |
| [Deployment](server/docs/deployment.md) | Native-vs-Docker performance, startup, upgrades, persistence, and backups |
| [Device setup](docs/device-setup.md) | Apple signing, keyboard installation, and physical-device acceptance |
| [Tailscale](server/docs/tailscale.md) | Private HTTPS ingress for the gateway |
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

- [CONTRIBUTING.md](CONTRIBUTING.md) — setup, required checks, and pull request expectations
- [SUPPORT.md](SUPPORT.md) — where to ask for help and what to include (or omit)
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) — Contributor Covenant 2.1
- [SECURITY.md](SECURITY.md) — private vulnerability reporting

Report suspected microphone, recording, token, gateway, or tailnet
vulnerabilities through the private process in [SECURITY.md](SECURITY.md), not a
public issue.

### License

vocaphone is licensed under the **GNU Affero General Public License v3.0**
([AGPL-3.0](LICENSE)), matching [VocaMac](https://github.com/VocaHQ/vocamac) and
staying in the same copyleft family as
[VocaLinux](https://github.com/VocaHQ/vocalinux) (GPL-3.0).

You may use, study, modify, and redistribute the software under AGPL-3.0. Because
vocaphone includes a network gateway, AGPL also requires that modified versions
offered as a network service make their corresponding source available.
