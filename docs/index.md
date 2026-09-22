---
title: VocaPhone documentation
description: Learn how to use, operate, understand, and contribute to VocaPhone.
---

# VocaPhone documentation

VocaPhone is a private voice keyboard for iPhone and Android. Speech-to-text
runs on the phone after a model download, or through an optional VocaGateway
that you run on hardware you control.

This site is organized around the task you are trying to complete. Each guide
states who it is for, what you need before starting, and how to verify the
result. The Markdown in this repository remains the single authored source;
the website is its permanent published reading experience.

## Start with a working dictation

Follow the [getting started tutorial](tutorials/getting-started.md) if you are
new to VocaPhone. It walks through the shortest working path on Android and
iPhone, then explains when you need a gateway.

## Choose a task

### Use VocaPhone

- [Get started](tutorials/getting-started.md) — install the app and complete
  your first dictation.
- [Set up a physical iPhone](how-to/device-setup.md) — configure signing,
  Full Access, the microphone, the keyboard, and the acceptance pass.
- [Troubleshoot a failure](how-to/troubleshooting.md) — start from a symptom
  and follow the shortest repair path.

### Operate a gateway

- [Deploy VocaGateway](how-to/deploy-gateway.md) — choose native or Docker,
  pair the phone, and keep the service private.
- [Connect over Tailscale](how-to/tailscale.md) — expose a loopback gateway
  through a private HTTPS path.

### Ship and maintain the project

- [Release VocaPhone](how-to/release.md) — understand tag names, artifacts,
  checks, and the Android/iOS release boundary.
- [Ship to TestFlight](how-to/testflight.md) — archive, upload, and distribute
  an iOS build.
- [Ship to Google Play](how-to/google-play.md) — upload the signed Android
  bundle and promote it from Internal testing.
- [Contribute](how-to/contribute.md) — find small, well-scoped entry points.
- [Maintain dependencies](reference/dependency-maintenance.md) — review and
  update the project safely.

### Understand the system

- [How the system fits together](explanation/architecture.md) — follow the
  recording, handoff, gateway, engine, and insertion boundaries.
- [Privacy and data handling](reference/privacy.md) — see what stays on the
  phone, what can reach a gateway, and what is retained.
- [Project decisions](reference/decisions.md) — find the identifiers and
  assumptions that other documentation relies on.

## Product boundaries

VocaPhone has no hosted transcription service. On-device transcription is the
default. Audio reaches another machine only when the user configures a
self-hosted VocaGateway, and that machine remains under the user's control.

The iOS keyboard extension cannot record audio. The containing iOS app owns the
microphone, shares versioned session state through the App Group, and inserts
the result through the text document proxy. Full Access enables that
coordination; it is not used for keylogging.

## Source and contribution links

- [Repository](https://github.com/VocaHQ/vocaphone)
- [Gateway repository](https://github.com/VocaHQ/vocagateway)
- [Contributing guide](https://github.com/VocaHQ/vocaphone/blob/main/CONTRIBUTING.md)
- [Security policy](https://github.com/VocaHQ/vocaphone/blob/main/SECURITY.md)
