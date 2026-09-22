---
title: Get started with VocaPhone
description: Install VocaPhone and complete a first private dictation on Android or iPhone.
---

# Get started with VocaPhone

This tutorial takes you from an installed app to a completed dictation. Use it
when you are new to VocaPhone and want the shortest path to a working result.

## Choose the phone you have

| Phone | Install | First transcription path |
| --- | --- | --- |
| Android 13 or newer | [Google Play](https://play.google.com/store/apps/details?id=com.vocahq.vocaphone) | Download an on-device speech-to-text model |
| iPhone with iOS 17 or newer | [Public TestFlight](https://testflight.apple.com/join/wd85wQ3W) | Download an on-device model or connect your gateway |

VocaPhone does not require an account or a Voca-hosted speech service. The
optional gateway is for users who want models or compute on a Mac, Linux
machine, or home server they operate.

## Android

1. Install VocaPhone from Google Play and open it once.
2. Grant microphone access and notification access when Android asks. The
   notification keeps foreground microphone capture visible.
3. Open Android keyboard settings, enable VocaPhone, and select it as the
   current keyboard.
4. In VocaPhone, open **Settings → Transcription → On this phone** and
   download a model.
5. Open Notes or another ordinary text field, select the VocaPhone keyboard,
   tap **Dictate**, speak a short sentence, and tap **Finish**.
6. Confirm that the transcript is inserted at the active cursor.

If the model is not ready, use [Troubleshooting](../how-to/troubleshooting.md)
or configure a [self-hosted gateway](../how-to/deploy-gateway.md).

## iPhone

1. Install the public TestFlight build and open VocaPhone once.
2. Grant microphone access.
3. Open **Settings → General → Keyboard → Keyboards → Add New Keyboard** and
   add **VocaPhone**.
4. Open VocaPhone's keyboard entry and enable **Allow Full Access**. Full
   Access lets the keyboard and containing app coordinate a dictation session;
   the keyboard does not record audio.
5. In VocaPhone, open **Settings → Transcription → On this iPhone** and
   download a model, or choose **Gateway** and enter the address and token for
   a gateway you operate.
6. Open Notes, select the VocaPhone keyboard, tap **Dictate**, and follow the
   app handoff if the keyboard asks you to return to Notes.
7. Tap **Finish**, then **Insert**, and confirm that the text appears in Notes.

For a signed source build or a complete hardware acceptance pass, continue to
[physical iPhone setup](../how-to/device-setup.md).

## Verify the privacy boundary

The normal path keeps audio on the phone. If you selected Gateway mode, the
phone sends audio only to the URL and bearer token you configured. The gateway
is self-hosted; VocaPhone does not send audio to a Voca cloud service.

Read [Privacy and data handling](../reference/privacy.md) when you need the
retention, token, keyboard, or optional usage-reporting details.

## What to do next

- [Deploy a gateway](../how-to/deploy-gateway.md) for more models or shared
  compute.
- [Set up a physical iPhone](../how-to/device-setup.md) for device-level
  acceptance testing.
- [Troubleshoot a failure](../how-to/troubleshooting.md) when a state or
  permission does not match the steps above.
