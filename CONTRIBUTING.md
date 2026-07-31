# Contributing

Thanks for helping improve Local Flow. Changes should preserve its privacy-first,
tailnet-only architecture and the documented iOS keyboard constraints.

## Development setup

- Install Xcode, XcodeGen, `uv`, and FFmpeg.
- Run `xcodegen generate --spec project.yml` from `ios/` after changing
  `ios/project.yml`.
- Never commit microphone recordings, bearer tokens, signing material, tailnet
  hostnames, local database files, or Apple provisioning profiles.

## Required checks

Run the gateway checks:

```sh
cd server
uv sync --all-groups
uv run ruff check .
uv run ruff format --check .
uv run mypy app
uv run pytest
```

Then build and test the iOS project on an installed simulator:

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

Keyboard, microphone, background-audio, and insertion changes must also be
verified on a physical iPhone. Describe the tested app, iOS version, and exact
interaction sequence in the pull request.

## Pull requests

- Keep changes focused and document user-visible behavior.
- Add or update tests for state transitions, gateway behavior, and regressions.
- Update README or `docs/` when setup, privacy, security, or architecture changes.
- Do not weaken loopback gateway binding, bearer authentication, upload limits,
  retention, or explicit microphone indicators without discussing the tradeoff.
