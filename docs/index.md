# VocaPhone documentation

VocaPhone is a private voice keyboard for iPhone and Android. Speech-to-text
runs on the phone after a model download, or through an optional VocaGateway
that you run on hardware you control.

Use this documentation to set up a device, understand the data flow, deploy a
gateway, and prepare a release.

## Find your way around

- [Set up a device](device-setup.md) — install the app and complete the
  physical-device acceptance checklist.
- [Understand the architecture](architecture.md) — see how recording,
  transcription, insertion, and the optional gateway fit together.
- [Read the privacy model](privacy.md) — follow audio, tokens, metrics, and
  keyboard boundaries.
- [Deploy a gateway](deployment.md) — connect a phone to a VocaGateway you
  operate.
- [Troubleshoot a failure](troubleshooting.md) — work through keyboard,
  microphone, model, network, and Docker issues.
- [Release the apps](releasing.md) — follow the tag, changelog, and store
  delivery contract.

The source for these pages stays in the repository's [`docs/` directory](https://github.com/VocaHQ/vocaphone/tree/main/docs), so edits remain reviewable as ordinary Markdown changes.

## Platform references

- [Android client](https://github.com/VocaHQ/vocaphone/tree/main/android) —
  build flavors, the voice keyboard, and Android-specific setup.
- [Gateway reference](https://github.com/VocaHQ/vocagateway) — native service,
  Compose, models, configuration, health, and CLI commands.
- [Contributing](https://github.com/VocaHQ/vocaphone/blob/main/CONTRIBUTING.md)
  — development workflow and required checks.
- [Security](https://github.com/VocaHQ/vocaphone/blob/main/SECURITY.md) —
  private vulnerability reporting.
