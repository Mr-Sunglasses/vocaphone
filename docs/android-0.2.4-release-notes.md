# VocaPhone Android 0.2.4

Version code: **32**. Release tag: **android/v0.2.4**.

0.2.4 is a fixes-and-speed release. Every change ships in both the keyboard
app (`vocaphone.apk`, Google Play) and VocaPhoneX (`vocaphone-x.apk`).

## Transcripts say what you said

- Dictating after typing part of a word no longer replaces it. Type "hel",
  tap the mic, say "Hello world", and the "hel" stays
  ([#379](https://github.com/VocaHQ/vocaphone/pull/379)).
- Names keep their capitals. Clean, Formal, Casual and Excited used to
  lowercase every Title-Case word ("I met sarah in paris"). Flattening now
  applies only to sentences a model Title-Cased as a whole, and imperatives
  such as "Do it tomorrow" no longer get a question mark ([#382](https://github.com/VocaHQ/vocaphone/pull/382)).
- Custom-vocabulary near-miss correction runs only on English transcripts,
  so "Der Wagen ist rot" no longer becomes "Der Wagner ist rot" when Wagner
  is in your vocabulary ([#394](https://github.com/VocaHQ/vocaphone/pull/394)).

## Faster on-device transcription

- Sherpa models decode the recording at natural pauses while you are still
  speaking, not only every 12 seconds, so a typical 5–10 s dictation has
  little left to decode after Finish
  ([#385](https://github.com/VocaHQ/vocaphone/pull/385)).
- Sherpa incremental decoding works again on the Fast and Accurate quality
  settings; it used to fall back to a whole-recording decode after Finish
  ([#383](https://github.com/VocaHQ/vocaphone/pull/383)).
- whisper.cpp uses only the phone's performance cores, so efficiency cores
  no longer set the pace ([#386](https://github.com/VocaHQ/vocaphone/pull/386)).

## Reliability

- Cancelling an on-device transcription stops promptly, deletes the
  recording, and no longer leaves a failed history entry with Retry
  ([#384](https://github.com/VocaHQ/vocaphone/pull/384)).
- When Android refuses to start the microphone service, the keyboard shows
  an error instead of sitting on "Ready" as if the tap never happened
  ([#380](https://github.com/VocaHQ/vocaphone/pull/380)).
- VocaPhoneX refreshes its bubble once typing pauses instead of on every
  keystroke in every app, and clipboard work no longer runs after a service
  is destroyed ([#381](https://github.com/VocaHQ/vocaphone/pull/381)).

## Upgrade notes

- Settings, models, gateway configuration and history carry over from 0.2.3.
- On-device dictation still stays on the phone after model download.
  Gateway dictation sends audio only to the gateway you configure.

## Changelog

- [#379](https://github.com/VocaHQ/vocaphone/pull/379), [#380](https://github.com/VocaHQ/vocaphone/pull/380),
  [#381](https://github.com/VocaHQ/vocaphone/pull/381), [#382](https://github.com/VocaHQ/vocaphone/pull/382),
  [#383](https://github.com/VocaHQ/vocaphone/pull/383), [#384](https://github.com/VocaHQ/vocaphone/pull/384),
  [#385](https://github.com/VocaHQ/vocaphone/pull/385), [#386](https://github.com/VocaHQ/vocaphone/pull/386),
  [#394](https://github.com/VocaHQ/vocaphone/pull/394): fixes and performance above.
- [#396](https://github.com/VocaHQ/vocaphone/pull/396): version bump and release metadata.
