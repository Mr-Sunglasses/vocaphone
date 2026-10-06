# VocaPhone Android 0.2.3

Version code: **31**. Release tag: **android/v0.2.3**.

The headline of 0.2.3 is a brand-new sibling app: **VocaPhoneX**, included
in this release as `vocaphone-x.apk`. Landed in
[PR #370](https://github.com/VocaHQ/vocaphone/pull/370).

## VocaPhoneX: dictation into any app, without changing keyboards

A lot of Android users are attached to Gboard, SwiftKey, or the Samsung
keyboard. VocaPhoneX exists for them: it is the same VocaPhone dictation
engine, minus the keyboard.

Install it, grant the permissions it asks for, and a small floating mic
bubble appears whenever you focus a text field, in any app. Tap the bubble
to start dictating, tap again to finish, and the transcript is written
straight into the field you were typing in through the accessibility API.
No keyboard switching, no clipboard juggling, no IME slot occupied.

Everything behind the mic is the same backend the keyboard app uses:

- On-device models (Whisper.cpp, Sherpa ONNX) or your own self-hosted
  VocaGateway.
- Language and dictation style controls, formatting, snippets, personal
  dictionary, history, and stats.
- Cancels and retries behave exactly like the keyboard app's dictation.

VocaPhoneX installs next to the main app, not over it: it is a separate
package (`com.vocahq.vocaphone.x`), so you can keep both. It is **sideload
only** and is not being published to Google Play; the Play listing remains
the full keyboard app.

VocaPhoneX asks for four things during setup: display over other apps so
the bubble can float, the accessibility service so it can see and write into
the focused field, the microphone to record, and notifications so the
recording and model-download states are visible. Field contents are read
only at the moment of insertion, are never stored, logged, or uploaded. The
full keyboard builds never request the overlay or accessibility
permissions.

## Which download is which

- **`vocaphone.apk`**: the VocaPhone you know: the custom keyboard with the
  mic built in. Same binary that goes to Google Play (the Play listing gets
  the signed AAB, not this file).
- **`vocaphone-x.apk`**: VocaPhoneX, the new floating-mic build described
  above. Sideload-only, separate package, installs alongside the main app.
- **`vocaphone-fdroid.apk`**: the F-Droid flavor: whisper.cpp only and no
  telemetry, published as the rebuild reference for F-Droid.
- **`*.cdx.json`**: CycloneDX software bill of materials for each APK.
- **checksums and attestations**: verify what you downloaded came from this
  tag's CI run.

## Fixes in 0.2.3

These controller fixes ride in both the keyboard app and VocaPhoneX:

- Cancel during recording or upload now unwinds in a fraction of a second.
  A stalled pipeline used to be able to sit on "Listening" forever; a bounded
  watchdog force-resets it instead.
- Retrying a dictation from the floating bubble re-inserts into the field
  instead of delivering to the companion app.
- A dictation queued behind another one keeps the microphone foreground
  service and its notification alive through the handoff instead of
  recording without them.
- Text insertion now replaces a real range selection instead of appending
  after it, and keeps appended inserts at the caret instead of at the end
  of the field.
- Dismissing the bubble is per-app: it stays hidden while you keep using
  the same app and comes back when you switch apps.

## Upgrade notes and limitations

- VocaPhoneX is emulator-tested end to end (bubble on field focus, dictate,
  transcript inserted, cancel, queued retries). Physical-device validation
  is still recommended before calling it done; an emulator mic is not a
  real phone mic.
- On first run, VocaPhoneX walks you through the disclosure and its
  permissions. If you skip the accessibility grant, the bubble cannot
  appear.
- Stored settings, models, gateway configuration, and history from 0.2.2
  carry over; VocaPhoneX keeps its own separate settings and history.
- On-device dictation still stays on the phone after model download.
  Gateway dictation sends audio only to the gateway you configure.

## Changelog

- [PR #370](https://github.com/VocaHQ/vocaphone/pull/370): VocaPhoneX
  floating-mic flavor, accessibility insertion, release artifacts.
- [PR #376](https://github.com/VocaHQ/vocaphone/pull/376): version bump and
  release metadata.
