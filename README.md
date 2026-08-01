# Local Flow

Local Flow is a privacy-first iPhone dictation keyboard backed by speech models
running on hardware you control. The keyboard coordinates recording through its
containing iOS app, sends recoverable audio to a private gateway, and inserts the
final transcript directly at the active cursor.

The complete keyboard handoff, background recording, private Tailscale
transcription, and direct text-insertion flow has been exercised on a physical
iPhone 14 Pro.

> [!IMPORTANT]
> iOS keyboard extensions cannot access the microphone. Local Flow records in
> the containing app, shares only versioned session state with the keyboard, and
> then inserts through `UITextDocumentProxy`. Quick Dictation can keep that app
> ready for up to 10 minutes so most later dictations do not require another app
> switch.

## Highlights

- Native SwiftUI app and UIKit keyboard with Start, Finish, Cancel, Retry, Undo,
  language/style status, next-keyboard control, and direct insertion
- Four local writing styles: Formal, Casual, Very Casual, and Excited
- Automatic microphone routing or an explicit iPhone Microphone preference,
  with the input currently in use shown in the app
- A bounded Quick Dictation window with persistent background input, a Live
  Activity/Dynamic Island timer, and standby buffers that are discarded
- FastAPI gateway with bounded uploads, SQLite idempotency, FFmpeg normalization,
  silence detection, retention cleanup, and stable error responses
- Handy, WhisperKit, persistent `faster-whisper`, experimental Moonshine, and
  `whisper.cpp` adapters with downloadable local models
- Operational dashboard with hardware detection, queue/outcome counters,
  pipeline benchmarks, real-time factor, peak memory, and warmup state
- CPU/OpenBLAS, host-native CPU, NVIDIA CUDA, and Vulkan Compose profiles
- Bearer authentication, iOS Keychain storage, configurable HTTP/HTTPS gateway
  access, optional private Tailscale HTTPS, no analytics, and no third-party
  transcription

## Choose a gateway deployment

| Deployment | Best for | Speech engine | Expected performance |
| --- | --- | --- | --- |
| Native macOS | Daily use on an Apple silicon Mac | WhisperKit, Handy, or `whisper.cpp` | Best on Apple silicon with WhisperKit |
| Docker Compose | Linux home servers and reproducible deployment | faster-whisper INT8, Moonshine, or accelerated `whisper.cpp` | Portable CPU by default; optional native/CUDA/Vulkan profiles |

On an Apple silicon Mac, use the native gateway with WhisperKit for the lowest
latency and lowest virtualization overhead. Local Flow keeps the selected Core
ML model resident in a loopback-only WhisperKit service instead of reloading the
CLI for every dictation. The current container deliberately uses a portable
Linux CPU backend and cannot use macOS Core ML from inside Docker Desktop.
Docker remains the recommended deployment for Linux home servers.
Precise speed depends on the model, audio duration, and hardware; compare the
same recording and model class before drawing benchmark conclusions.

See [deployment choices](docs/deployment.md) for the complete comparison and
operational commands.

## Quick start

### 1. Start the gateway natively on macOS

Install the tools and launch the server:

```sh
brew install ffmpeg whisperkit-cli
cd server
uv sync --all-groups --extra engines
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

### 2. Or start it with Docker Compose

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
recommended `faster-whisper` model. Readiness returns `503` until a runnable
model is selected:

```sh
curl --fail http://127.0.0.1:8765/health/ready
```

Copy [server/.env.example](server/.env.example) if you prefer an editable
template. Never commit the resulting `.env` file.

### 3. Choose how the iPhone reaches the gateway

The app accepts any valid `http://` or `https://` gateway URL. Choose one of
these network arrangements:

- **Trusted LAN:** bind/publish the gateway on the LAN and enter a URL such as
  `http://homelabone:8765/`. HTTP is unencrypted, so use this only on a network
  you trust and never forward that port to the internet.
- **Tailscale:** keep the gateway on loopback and let Tailscale Serve provide
  tailnet-only HTTPS:

```sh
tailscale serve --bg 8765
tailscale serve status
```

- **VPS or public DNS:** put the loopback gateway behind an HTTPS reverse proxy
  with a trusted certificate and enter a URL such as
  `https://dictation.example.com/`. Do not send recordings or bearer tokens over
  public HTTP.

Tailscale is recommended for a private personal deployment, but it is not
mandatory. Follow [deployment](docs/deployment.md) and the optional
[Tailscale guide](docs/tailscale.md) for the relevant host configuration.

### 4. Configure and install the iPhone app

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
4. Add Local Flow under **Settings → General → Keyboard → Keyboards** and enable
   Full Access.
5. In Local Flow, enter the reachable HTTP/HTTPS gateway URL and bearer token,
   then use **Save and test**. Approve Local Network access when using a LAN host.

Complete the physical-device checklist in [device setup](docs/device-setup.md).

## Build and test

Gateway checks:

```sh
cd server
uv sync --all-groups --extra engines
uv run ruff check .
uv run ruff format --check .
uv run mypy app
uv run pytest
LOCALFLOW_TOKEN=test-token-with-at-least-thirty-two-characters docker compose config --quiet
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
server/app/             FastAPI gateway, engines, model manager, WebUI
server/tests/           Gateway unit and integration tests
server/compose.yaml     Canonical container deployment
server/Dockerfile*      CPU, NVIDIA CUDA, and Vulkan images
docs/                   Architecture, setup, operations, privacy, decisions
Plan.md                 Original implementation plan and acceptance criteria
```

## Documentation

| Guide | Covers |
| --- | --- |
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
  If Quick Dictation expires, Local Flow must open and the user returns manually.
- Secure fields and apps that disable third-party keyboards remain iOS platform
  limitations.

## Contributing, security, and license

Follow [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request. Report
suspected microphone, recording, token, gateway, or tailnet vulnerabilities
through the private process in [SECURITY.md](SECURITY.md), not a public issue.

No open-source license has been selected. Unless a license is added later, the
repository is source-available for review but does not grant permission to copy,
modify, or redistribute the code.
