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

- Install Xcode, XcodeGen, `uv`, and FFmpeg.
- For Android work, install a recent Android Studio / SDK and JDK 17+.
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

For Android changes, run the project unit tests from `android/` and note whether
the floating bubble was exercised on a physical device.

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
