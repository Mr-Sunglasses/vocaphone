# VocaPhone Android plan

## Current direction

VocaPhone ships as a native Android voice keyboard for Android 13 and newer.
The user enables and selects VocaPhone from Android's input-method settings,
then taps Dictate inside the keyboard. The transcript is committed through the
focused editor's `InputConnection`.

This is an intentional permission-minimal design. The release APK does not
declare or request `AccessibilityService`, `SYSTEM_ALERT_WINDOW`, or battery
optimization exemptions. It does not inspect other apps, enumerate launcher
packages, scrape editor contents, or use a clipboard workaround.

## Architecture

- Kotlin and Jetpack Compose companion app.
- `InputMethodService` keyboard with a small dictation control surface.
- One application-scoped `DictationController` shared by the companion app,
  keyboard, and microphone foreground service.
- `AudioRecord` owned by a microphone foreground service, with transient audio
  focus and route/interruption recovery.
- Existing HTTP/WebSocket gateway protocol; no Android-specific transcription
  backend or cloud service.
- Android Keystore encryption for the gateway token.
- Room history with immediate successful-audio deletion and bounded retry
  retention for failures.

## First-run setup

The guided checklist requires only:

1. Microphone permission.
2. Notification permission, so the microphone foreground service can be visible.
3. VocaPhone enabled and selected as the current keyboard.
4. A reachable gateway URL and bearer token.

Setup is re-read on resume. If the user changes the current keyboard or revokes a
runtime permission, the companion app explains the exact repair action. A
companion-app scratchpad remains available for testing without selecting the
keyboard.

## Dictation lifecycle

The keyboard starts a single shared session, shows recording state, elapsed time,
input level and any streaming partial transcript, and sends Finish or Cancel to
the controller. The controller:

- requests microphone audio focus before capture;
- treats phone calls, media-service resets, route loss and other interruptions
  as a failed session rather than pretending recording continued;
- keeps the microphone foreground service only while capture is active;
- prefers the streaming gateway endpoint and falls back to the bounded WAV path;
- sanitizes empty/marker-only output before insertion;
- commits only cleaned transcript text through `InputConnection`;
- retains failed audio only for the configured retry window.

Password and other sensitive input types are rejected by the IME input policy.
The keyboard never reads surrounding editor text to decide whether to show the
microphone or to construct an insertion. With Suggestions enabled it may read
about 32 characters before the cursor, only in non-sensitive fields, so it can
guess the next word. That text stays on the device and is never logged. The
clipboard paste chip reads the current clip only while the input view is
showing; dictation still never uses the clipboard.

## Privacy and diagnostics

Operational diagnostics may include timestamps, state transitions, error codes,
source surface, build version and audio-route labels. They must never include
transcripts, typed text, audio, gateway URLs/hosts, tokens, or arbitrary package
lists. Any persistent diagnostic buffer must be bounded and redact before it is
written.

## Verification gates

- `./gradlew assembleFullDebug testFullDebugUnitTest lintFullDebug` is green.
- `./gradlew assembleFullRelease` is green with release shrinking enabled.
- `./gradlew assembleFdroidRelease` is green, and the APK it produces carries no
  prebuilt native library.
- The merged/release manifest contains no accessibility-service declaration,
  overlay permission, battery-exemption permission, or launcher-app query.
- A signed release installs on the baseline device, appears in the IME list,
  can be enabled and selected, and renders the keyboard.
- Unit tests cover input-type policy, insertion arithmetic, transcript
  sanitization, interruption state, audio focus, and diagnostic redaction.
- Physical-device testing covers microphone permission changes, keyboard
  switching, calls/route changes, app force-stop, and insertion into ordinary
  and sensitive fields.

## Deliberately out of scope

A floating bubble/accessibility implementation is not part of the release path.
It would require a separate product, policy and privacy review and would bring
back the restricted-settings and overlay friction this architecture removes.
Local speech models are also not bundled in the phone client yet; transcription
continues to run on the user-controlled gateway where model choice and resource
limits can be managed centrally.

Daily-driver QWERTY changes (number row, height, suggestions, emoji search,
clipboard chip) are proposed in
[Plan-Android-Keyboard-UX.md](Plan-Android-Keyboard-UX.md) and are not part of
this architecture document until accepted.
