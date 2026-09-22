---
title: Deploy VocaGateway for VocaPhone
description: Run the optional self-hosted gateway and connect a VocaPhone device to it.
---

# Deploy VocaGateway for VocaPhone

Use this guide when you want transcription on a Mac, Linux machine, or home
server that you operate. On-device transcription does not need a gateway.

VocaGateway is a separate project. This guide explains the phone-facing
decisions; use the [VocaGateway deployment guide](https://github.com/VocaHQ/vocagateway/blob/main/docs/deployment.md)
for installation, model engines, configuration, and service management.

## Before you start

- Choose a host you control and can keep available while you dictate.
- Choose native or Docker deployment in the gateway documentation.
- Choose a private network path: a trusted LAN, Tailscale Serve, or HTTPS.
- Keep the gateway bearer token private.

## 1. Install and start the gateway

Follow the gateway project's [quick start](https://github.com/VocaHQ/vocagateway#quick-start)
or [full deployment guide](https://github.com/VocaHQ/vocagateway/blob/main/docs/deployment.md).
Confirm that the service is healthy before configuring the phone.

The gateway should listen on loopback by default. If the phone is on another
machine, use a trusted LAN address, a private Tailscale path, or an HTTPS
reverse proxy. Do not expose an unauthenticated gateway to the public internet.

For the gateway's Tailscale setup, use the
[gateway Tailscale guide](https://github.com/VocaHQ/vocagateway/blob/main/docs/tailscale.md).

## 2. Connect VocaPhone

On Android, open **Settings → Transcription → Gateway**. On iPhone, open
**Settings → Transcription → Gateway**.

Enter the gateway's HTTP or HTTPS URL and bearer token. The URL can be a
trusted LAN address, a Tailscale Serve URL, or an HTTPS host you control. If
the gateway exposes a pairing QR, use **Scan pairing QR code** instead and
approve camera and Local Network access when prompted.

Return to the Transcription screen and wait for it to report **Ready**. Gateway
mode should name the speech-to-text model that the gateway loaded.

## 3. Verify a complete request

1. Open an ordinary text field in Notes or another host app.
2. Select the VocaPhone keyboard.
3. Start a short dictation and finish it.
4. Confirm the transcript appears at the active cursor.
5. Confirm the gateway reports the request without exposing the transcript or
   bearer token in ordinary logs.

If the gateway is reachable but its model is not ready, follow the gateway's
[model and engine troubleshooting](https://github.com/VocaHQ/vocagateway/blob/main/docs/troubleshooting.md).
For phone-side failures, use [VocaPhone troubleshooting](troubleshooting.md).

## Migrate from an older Local Flow installation

The product identifiers changed to `com.vocahq.vocaphone` and
`group.com.vocahq`. Existing installations do not upgrade in place.

- **iOS:** remove the old app, rebuild with the current bundle IDs, register
  the current App Group, reinstall, and pair again.
- **Android:** uninstall `io.github.mrsunglasses.localflow` before installing
  `com.vocahq.vocaphone`. The old token ciphertext is not portable between
  application IDs, so enter the token and pair again.

Check [project decisions](../reference/decisions.md) before changing any
identifier or deployment assumption.
