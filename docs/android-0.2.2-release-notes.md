# VocaPhone Android 0.2.2

Version code: **30**. Intended release tag: **android/v0.2.2**.

Includes the fixes from [Android PR #364](https://github.com/VocaHQ/vocaphone/pull/364).

## Fixes

- Android 13 setup recognizes the selected VocaPhone keyboard and can advance
  past the keyboard step (#339).
- Dictated corrections receive spaces between neighboring words, including
  when inserted immediately after a sentence-ending dot (#357).
- Automatic microphone routing uses the phone microphone when a Bluetooth
  headset is connected, avoiding automatic headset call mode (#306). Choose
  **Bluetooth headset** explicitly to use its microphone. Failed or cancelled
  capture startup also returns audio focus and the communication route.
- The ongoing dictation notification follows the actual dictation job through
  transcription and clears when it ends, including very short recordings (#171).
  A startup repair also clears the microphone notification while model download
  or preparation progress continues.

## Other changes since 0.2.1

- Long on-device Whisper dictations preserve speech across 30-second windows.
- On-device models recover after unloading, and setup prepares the model before
  the first dictation. Settings, model selection and onboarding are simpler.
- Optional automatic finish after a pause, and custom-word handling across local
  models.
- Updated model catalog including Qwen3-ASR 0.6B and Omnilingual. Dolphin Small
  and Paraformer Small are retired; existing selections follow the model migration.
- Optional self-hosted gateway uploads overlap recording, with compressed
  completed-file fallback. Supporting gateways return text in the upload response.
- Android dependencies and the pinned whisper.cpp runtime are updated. Release
  assets include dependency inventories and build attestations.

## Upgrade and limitations

Stored microphone choices remain saved. Automatic's Bluetooth behavior changes
as described above; explicit Bluetooth keeps its telephone-quality input and
playback-quality trade-off while recording. Android has the final say on routing.

On-device dictation stays on the phone after model download. Gateway dictation
sends audio only to the optional gateway the user configures.

The separate HeliBoard voice-bar placement fix (#270 / PR #284) and backspace
hold-cadence fix (#298 / PR #301) are not included in this preparation.
Physical Android 13 onboarding, Bluetooth playback and immediate Start/Finish
checks remain deferred; the release has been requested with that validation
outstanding. See [device checks](device-setup.md) for the follow-up sequence.

The release workflow publishes signed APK/AAB files on GitHub and uploads the
full AAB to Play Internal when configured. Production rollout remains a Play
Console action.
