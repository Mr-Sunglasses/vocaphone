# Support

Thanks for trying vocaphone. Use this guide to get help without opening the wrong kind of issue.

## Before you ask

1. Confirm you are on the latest `main` commit (or a released build, when those exist).
2. Read [docs/troubleshooting.md](docs/troubleshooting.md) for common setup and runtime failures.
3. Check [docs/device-setup.md](docs/device-setup.md) for iOS keyboard / Android bubble setup.
4. Check [docs/deployment.md](docs/deployment.md) for gateway, Docker, Tailscale, and HTTPS setup.
5. Search [existing issues](https://github.com/VocaHQ/vocaphone/issues) for the same problem.

## Where to get help

| Topic | Where |
| --- | --- |
| Setup, usage, or "how do I…?" questions | [GitHub Discussions](https://github.com/VocaHQ/vocaphone/discussions) (when enabled) or a clearly titled issue using the question/feature templates |
| Reproducible bugs | [Bug report](https://github.com/VocaHQ/vocaphone/issues/new?template=bug_report.yml) |
| Feature ideas | [Feature request](https://github.com/VocaHQ/vocaphone/issues/new?template=feature_request.yml) |
| Security or privacy vulnerabilities | [SECURITY.md](SECURITY.md) — never a public issue |
| Contributing code or docs | [CONTRIBUTING.md](CONTRIBUTING.md) |
| Community standards | [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) |

## What to include

When you ask for help, include:

- Component: iOS app, keyboard, Android bubble, native gateway, or Docker gateway
- Exact versions: OS, Xcode/Android SDK/Python as relevant, and the git commit or release
- What you expected vs what happened
- Redacted steps to reproduce
- Redacted logs (see below)

## Do not include

Never paste:

- Microphone recordings or transcripts
- Bearer tokens, `.env` values, or signing material
- Private Tailscale hostnames or internal URLs that identify your network
- Apple provisioning profiles or keystore files
- Screenshots that show personal messages, contacts, or credentials

Replace secrets with placeholders such as `<token>`, `<tailnet-host>`, or `<user-id>`.

## Maintainer contact

For private security reports or conduct concerns, email [hello@vocahq.com](mailto:hello@vocahq.com). For everything else, prefer GitHub so other contributors can help and the answer stays searchable.
