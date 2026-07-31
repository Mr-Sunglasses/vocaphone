# Local Flow

Local Flow is a privacy-first iPhone dictation keyboard backed by a speech model
running on your own Mac. The keyboard coordinates recording through its
containing iOS app, sends recoverable audio over a private Tailscale connection,
and inserts the final transcript directly at the active cursor.

The iOS app and Mac gateway are implemented. The complete keyboard handoff,
background recording, private tailnet transcription, and text insertion flow has
been exercised on a physical iPhone 14 Pro.

## What is included

- SwiftUI containing app with onboarding, microphone permission, gateway pairing,
  health checks, persistent background audio, WAV recording, metering, and recovery
- UIKit custom keyboard with a compact QWERTY typing surface, Start, Finish,
  Cancel, Retry, Undo, language/style status, next-keyboard control, optional
  automatic insertion, and direct `UITextDocumentProxy` insertion
- Persistent return-gesture guidance plus a Live Activity/Dynamic Island timer
  and Finish control while the containing app records in the background
- A 10-minute Quick Dictation window that keeps the containing app's microphone
  input ready, discards standby buffers, and lets later keyboard taps start
  without leaving the current app
- Atomic, versioned App Group session records with validated transitions and
  duplicate-insertion protection
- Bearer token stored in the iOS Keychain, never in shared session JSON
- FastAPI gateway bound to loopback with bounded uploads, SQLite persistence,
  FFmpeg normalization, silence detection, and a model-independent adapter
- Handy and `whisper.cpp` adapters, private health/model endpoints, retry,
  retention cleanup, and stable machine-readable errors
- Unit and integration tests for Swift state/storage/spacing and Python API,
  auth, idempotency, upload limits, FFmpeg, silence detection, and cleanup

## Confirmed local environment

Recorded on 2026-07-31:

- macOS 26.5.2 on a 16 GB Apple M1 Pro MacBook Pro
- Xcode 26.6, Swift 6.3.3, and iOS 26.5 Simulator
- Python 3.13.5 managed by `uv` 0.8.0
- FFmpeg 8.1.2
- XcodeGen 2.46.0

A physical iPhone 14 Pro on iOS 26.6 is connected. Automatic Apple development
signing, App Group provisioning, the private Tailscale gateway, and Handy's local
model have all been exercised on-device.

## Build and test

These commands were run successfully in this checkout:

```sh
cd ios
xcodegen generate --spec project.yml
xcodebuild \
  -project LocalFlow.xcodeproj \
  -scheme LocalFlow \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

```sh
cd server
uv sync --all-groups
uv run ruff check .
uv run mypy app
uv run pytest
```

The generated [Xcode project](ios/LocalFlow.xcodeproj/project.pbxproj) is checked
in. Regenerate it after changing `ios/project.yml`.

## Configure the Mac gateway

Handy is detected automatically when installed. The gateway reuses Handy's
selected, already-downloaded model through its headless file-transcription
interface. If that model errors or returns an empty result, the gateway retries
with Handy's downloaded multilingual Whisper Base model. Create a private token
and start the gateway:

```sh
cd server
./scripts/setup-token.sh
uv run localflow-server
```

To force a specific Handy model:

```sh
export LOCALFLOW_ENGINE=handy
export LOCALFLOW_HANDY_MODEL='owner/repository/model.gguf'
export LOCALFLOW_HANDY_FALLBACK_MODEL='owner/repository/fallback-model.gguf'
```

To use standalone `whisper.cpp` instead:

```sh
export LOCALFLOW_ENGINE=whisper.cpp
export LOCALFLOW_WHISPER_BINARY=/absolute/path/to/whisper-cli
export LOCALFLOW_WHISPER_MODEL=/absolute/path/to/ggml-model.bin
```

The server listens only on `127.0.0.1:8765`. A local health check does not require
the token:

```sh
curl --fail --silent http://127.0.0.1:8765/health
```

Keep this loopback binding and use Tailscale Serve for private HTTPS. Do not use
Funnel. See [Tailscale setup](docs/tailscale.md) and [privacy](docs/privacy.md).

## Configure the iPhone project

Before distributing under your own identity, replace all four placeholders
consistently:

- `com.example.localflow`
- `com.example.localflow.keyboard`
- `com.example.localflow.liveactivity`
- `group.com.example.localflow`

Sign in to an Apple account in Xcode, set its Personal or Developer Team,
register the App Group for the app, keyboard, and Live Activity targets, and
follow [device setup](docs/device-setup.md). The minimum iOS version is currently
an assumption set to iOS 17.0.

## Product truth

iOS keyboard extensions cannot access the microphone. The containing Local Flow
app therefore owns microphone permission and recording. With Quick Dictation
enabled, opening Local Flow once arms a clearly indicated background microphone
input for up to 10 minutes. Standby buffers are discarded and are never saved or
uploaded. During that window, later Dictate taps signal the already-running app
through the App Group and stay in the current app. If the window expires or iOS
stops the audio session, the keyboard automatically falls back to opening Local
Flow. iOS does not provide a public API for reopening an arbitrary previous app,
so that fallback still asks the user to return manually. Clipboard insertion is
not used.

See [architecture](docs/architecture.md), [troubleshooting](docs/troubleshooting.md),
and the [decision log](docs/decisions.md).

## Contributing and security

Before opening a pull request, follow [CONTRIBUTING.md](CONTRIBUTING.md) and run
the iOS and gateway checks documented above. Please report suspected security or
privacy vulnerabilities through the private process in [SECURITY.md](SECURITY.md),
not through a public issue.

No open-source license has been selected yet. Unless a license is added later,
the repository is source-available for review but does not grant permission to
copy, modify, or redistribute the code.
