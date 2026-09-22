---
title: Connect VocaPhone through Tailscale
description: Route private HTTPS traffic from a phone to a self-hosted VocaGateway.
---

# Connect VocaPhone through Tailscale

Use this guide when the phone and gateway are on different networks and you
want private HTTPS without exposing the gateway to the public internet.

## Before you start

- The gateway is running on a host you control.
- Tailscale is installed and signed in on the gateway host and phone.
- You can reach the gateway locally on the host.
- You have the gateway bearer token.

## 1. Serve the gateway privately

Follow the gateway project's [Tailscale Serve guide](https://github.com/VocaHQ/vocagateway/blob/main/docs/tailscale.md).
Configure Serve to forward to the gateway's local listener and use the HTTPS
URL that Tailscale provides.

Do not use Tailscale Funnel for a normal VocaPhone installation. Serve keeps
the endpoint inside your tailnet; the gateway token still authenticates the
request.

## 2. Configure the phone

In VocaPhone, open **Settings → Transcription → Gateway** and enter:

- the HTTPS Serve URL;
- the gateway bearer token.

The URL must be the Tailscale HTTPS address, not the gateway's loopback URL.
You can also scan the gateway's pairing QR if it includes the Serve address.

## 3. Verify the connection

1. Wait for the Transcription screen to report **Ready**.
2. Confirm that it names the model loaded by the gateway.
3. Dictate one short sentence into an ordinary text field.
4. Confirm the transcript is inserted at the cursor.

If the phone cannot connect, check that both devices are signed in to the same
tailnet, the gateway is healthy, and the Serve target is still running. Then
follow [gateway troubleshooting](https://github.com/VocaHQ/vocagateway/blob/main/docs/troubleshooting.md)
before changing the phone's token.
