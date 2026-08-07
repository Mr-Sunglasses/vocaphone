# Contributing

Thanks for helping improve vocaphone. Changes should keep the privacy-first architecture, the documented
network-exposure controls, and the iOS keyboard constraints intact.

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
uv sync --all-groups --extra engines
uv run ruff check .
uv run ruff format --check .
uv run mypy app
uv run pytest
```

For container changes, also run:

```sh
cd server
VOCAPHONE_TOKEN=test-token-with-at-least-thirty-two-characters docker compose config
docker build --tag vocaphone-gateway:test .
```

When changing documentation, check local links and commands against the current
repository layout, then run `git diff --check`. Do not publish machine-specific
paths, real tailnet hostnames, tokens, recordings, or transcript samples.

Then build and test the iOS project on an installed simulator:

```sh
cd ios
xcodegen generate --spec project.yml
xcodebuild \
  -project VocaPhone.xcodeproj \
  -scheme VocaPhone \
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
