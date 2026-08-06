<div align="center">

# vocaphone

**Voice dictation for iPhone and Android.**

[![Status: in development](https://img.shields.io/badge/status-in%20development-yellow)](#status)
[![Platform: iOS + Android](https://img.shields.io/badge/platform-iOS%20%2B%20Android-lightgrey)](#how-it-works)
[![Privacy: self-hosted](https://img.shields.io/badge/privacy-self--hosted%20%2F%20no%20cloud%20STT-success)](#privacy-and-platform-boundaries)
[![Part of VocaHQ](https://img.shields.io/badge/family-VocaHQ-1a7f4e)](https://github.com/VocaHQ)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

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

Dictate from an iPhone keyboard or an Android floating bubble. Audio goes to a
gateway on your Mac, Linux box, or home server. Local speech models turn it into
text, and the transcript lands at your cursor. No accounts, no cloud STT, and no
subscription.

> Working name in code and binaries is still **Local Flow**
> (`localflow-server`, `com.example.localflow`, ...). Product name in prose and
> on GitHub is **vocaphone**. Bundle IDs and package names will catch up before
> a public release.

## Status

| Client | State |
| --- | --- |
| **iOS** | End-to-end flow exercised on a physical iPhone 14 Pro: keyboard handoff, background recording, private Tailscale transcription, direct insertion |
| **Android** | Builds and passes unit tests; floating-bubble client not yet exercised end to end on a physical Pixel |
| **Gateway** | Runs natively on macOS/Linux or via Docker Compose, with multiple local engine adapters |

No open-source license has been selected yet. Until one is added, the
repository is source-available for review but does not grant permission to copy,
modify, or redistribute the code.

## How it works

On iPhone, vocaphone is a custom keyboard plus a containing app. iOS keyboard
extensions cannot access the microphone, so the app records, shares only
versioned session state with the keyboard, and inserts through
`UITextDocumentProxy`. Quick Dictation can keep the app ready for up to 10
minutes so most later dictations skip another app switch.

On Android, your own keyboard stays put. A floating bubble starts and stops
dictation and inserts at the focused field, with the same styles and gateway as
iOS.

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
limits, Android accessibility consent, and what the bubble will never touch
(password fields, payment screens, apps you exclude).

## Highlights

- Native SwiftUI app and UIKit keyboard with Start, Finish, Cancel, Retry, Undo,
  language/style status, next-keyboard control, and direct insertion
- Native Kotlin/Compose Android client that keeps your own keyboard and dictates
  through a floating bubble, with the same styles and gateway as the keyboard
- 11 selectable transcription languages plus Automatic on Android (9 on iOS,
  pending French and German), and four writing styles: Formal, Casual, Very
  Casual, and Excited
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

## Quick start

### 1. Start the gateway natively on macOS

Install the tools (FFmpeg, plus the WhisperKit and `whisper.cpp` CLIs) and
launch the server:

```sh
brew install ffmpeg whisperkit-cli whisper-cpp
cd server
uv sync --all-groups --extra engines --extra apple
uv run localflow-server
```

The first run creates a private bearer token at
`~/.config/localflow/token`. Open `http://127.0.0.1:8765/`, enter that token,
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
uv run localflow-server
```

Omit the `apple` extra on Linux; MLX Audio and WhisperKit are macOS-only. The
startup banner prints the WebUI URL and where the bearer token lives:

```text
Local Flow gateway listening on 0.0.0.0:8765
WebUI (this host): http://127.0.0.1:8765/
Network access: use this host's LAN or Tailscale IP with the same port
Token: ~/.config/localflow/token
  (cat ~/.config/localflow/token — enter that value in the phone app)
```

Open the WebUI, enter the token from `~/.config/localflow/token`, download a
recommended model (SenseVoice Small INT8 or Parakeet TDT INT8 on CPU), select it,
and confirm Overview shows **Ready for dictation**.

To keep the gateway running after the terminal closes (systemd user unit):

```sh
cd server
./scripts/install-systemd-user.sh
# optional: survive logout
loginctl enable-linger "$USER"
```

Logs: `journalctl --user -u com.example.localflow.gateway.service -f`.

### 3. Or start it with Docker Compose

The canonical Compose file is [server/compose.yaml](server/compose.yaml). It
publishes the gateway only on host loopback by default and stores models,
configuration, and the session database in a named volume.

```sh
cd server
umask 077
printf 'LOCALFLOW_TOKEN=%s\n' "$(openssl rand -hex 32)" > .env
printf 'LOCALFLOW_PUBLISH_HOST=127.0.0.1\n' >> .env
printf 'LOCALFLOW_PUBLISH_PORT=8765\n' >> .env
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
  `LOCALFLOW_PUBLISH_HOST=0.0.0.0` in `server/.env` and protect the port with the
  host firewall. The container's own address auto-discovery (used by the
  pairing QR) can't see the host's LAN IP under the default bridge network
  either; on Linux Docker Engine, set `LOCALFLOW_NETWORK_MODE=host` in
  `server/.env` instead so discovery finds it directly — see
  [server/README.md](server/README.md#configuration).
- **Tailscale:** keep the gateway on loopback and let Tailscale Serve provide
  tailnet-only HTTPS:

```sh
# optional: bind loopback only when using Serve
# LOCALFLOW_BIND_HOST=127.0.0.1 uv run localflow-server
tailscale serve --bg 8765
tailscale serve status
```

- **VPS or public DNS:** put the loopback gateway behind an HTTPS reverse proxy
  with a trusted certificate and enter a URL such as
  `https://dictation.example.com/`. Do not send recordings or bearer tokens over
  public HTTP.

### Pair the phone with a QR code (iPhone or Android)

Once the WebUI is open and authenticated on the gateway host:

1. Stay on **Overview** — the **Pair phone app** card shows a QR for a
   phone-reachable address (LAN IP preferred, or `LOCALFLOW_PUBLIC_URL` if set).
2. To give this phone its own revocable credential instead of the shared
   bootstrap token, use **Or pair a new device with its own token**: name the
   device and the card immediately shows a QR for that device's token alone.
   The **Token to encode** dropdown switches the QR between the bootstrap
   token and any device token created this way; manage or revoke them later
   from Settings → **Paired device tokens**.
3. In the iPhone app, open **Settings** and tap **Scan pairing QR code**. On
   Android, open **Gateway** and tap **Scan QR code**.
4. Grant camera access if asked; the scan fills address + token and runs the
   connection test.

You can still paste manually:

1. **Gateway address** — the LAN, Tailscale, or HTTPS URL above.
2. **Bearer token** — `cat ~/.config/localflow/token` for native installs, or the
   `LOCALFLOW_TOKEN` value from `server/.env` for Docker.

Then use **Save and test** / **Test connection**. Tailscale is recommended for a
private personal deployment, but it is not mandatory. Follow
[deployment](docs/deployment.md) and the optional
[Tailscale guide](docs/tailscale.md) for the relevant host configuration.

### 5. Configure and install the iPhone app

Before signing under your own Apple account, replace these placeholders
consistently in the Xcode project configuration and entitlements:

- `com.example.localflow`
- `com.example.localflow.keyboard`
- `com.example.localflow.liveactivity`
- `group.com.example.localflow`

Then:

1. Generate/open `ios/LocalFlow.xcodeproj` and select your Apple development team.
2. Register the same App Group for the app, keyboard, and Live Activity targets.
3. Install the containing app on the iPhone and grant microphone permission.
4. Add the keyboard under **Settings → General → Keyboard → Keyboards** and enable
   Full Access.
5. In the app, enter the reachable HTTP/HTTPS gateway URL and bearer token,
   then use **Save and test**. Approve Local Network access when using a LAN host.

Complete the physical-device checklist in [device setup](docs/device-setup.md).

### 6. Or install the Android app

Android keeps your existing keyboard and dictates through a floating bubble
instead. Build and install the APK, then follow the guided setup in the app:

```sh
cd android
# macOS default; on Linux try $HOME/Android/Sdk
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/local-flow-debug.apk
```

In the app: grant microphone, notifications, overlay, and accessibility; then
enter the gateway address and bearer token from step 4 and run **Test connection**.

The same placeholder application ID, `com.example.localflow.android`, should be
replaced before you distribute a build. See the
[Android client guide](android/README.md) for permissions, the accessibility
disclosure, and the supported gateway address forms.

## Build and test

Gateway checks:

```sh
cd server
# On macOS add --extra apple for MLX / WhisperKit tooling in the dev environment.
uv sync --all-groups --extra engines
uv run ruff check .
uv run ruff format --check .
uv run mypy app
uv run pytest
LOCALFLOW_TOKEN=test-token-with-at-least-thirty-two-characters docker compose config --quiet
```

Android checks:

```sh
cd android
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
./gradlew assembleDebug testDebugUnitTest lintDebug
```

iOS checks:

```sh
cd ios
xcodegen generate --spec project.yml
xcodebuild \
  -project LocalFlow.xcodeproj \
  -scheme LocalFlow \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

The generated Xcode project is checked in. Regenerate it after changing
`ios/project.yml`. Keyboard, microphone, background audio, and insertion changes
still require physical-device verification.

## Project layout

```text
ios/                    Swift app, keyboard, Live Activity, shared state, tests
android/                Kotlin app, dictation bubble, accessibility service, tests
server/app/             FastAPI gateway, engines, model manager, WebUI
server/tests/           Gateway unit and integration tests
server/compose.yaml     Canonical container deployment
server/Dockerfile*      CPU, NVIDIA CUDA, and Vulkan images
docs/                   Architecture, setup, operations, privacy, decisions
Plan.md                 Original implementation plan and acceptance criteria
Plan-Android.md         Android implementation plan and acceptance criteria
```

## Documentation

| Guide | Covers |
| --- | --- |
| [Android client](android/README.md) | Building the APK, guided setup, the dictation bubble, and accessibility disclosure |
| [Gateway reference](server/README.md) | Native service, Compose, models, configuration, health, and CLI commands |
| [Deployment](docs/deployment.md) | Native-vs-Docker performance, startup, upgrades, persistence, and backups |
| [Device setup](docs/device-setup.md) | Apple signing, keyboard installation, and physical-device acceptance |
| [Tailscale](docs/tailscale.md) | Private HTTPS ingress and iPhone connectivity |
| [Architecture](docs/architecture.md) | Components, state transitions, engine boundary, and observability |
| [Privacy](docs/privacy.md) | Audio lifecycle, authentication, metrics, and threat model |
| [Troubleshooting](docs/troubleshooting.md) | Keyboard, microphone, model, network, and Docker failures |
| [Decisions](docs/decisions.md) | Current assumptions and choices still requiring confirmation |
| [Contributing](CONTRIBUTING.md) | Development workflow and required checks |
| [Security](SECURITY.md) | Private vulnerability-reporting process |

## Privacy and platform boundaries

- The keyboard never records audio and never uses clipboard insertion.
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
- On Android, accessibility access is used only to identify the focused editable
  field and to insert the transcript the user asked for; field contents are read
  in memory at insertion time and never stored, logged, or uploaded.
- The Android bubble stays hidden in password and payment fields, on system
  permission screens, and in any app the user excludes.

## Contributing, security, and license

Follow [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request. Report
suspected microphone, recording, token, gateway, or tailnet vulnerabilities
through the private process in [SECURITY.md](SECURITY.md), not a public issue.

No open-source license has been selected. Unless a license is added later, the
repository is source-available for review but does not grant permission to copy,
modify, or redistribute the code.
