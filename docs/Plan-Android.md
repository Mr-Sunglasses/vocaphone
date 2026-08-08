# vocaphone Android App Plan

## Summary

Build a native Android 13+ app with full vocaphone prototype parity,
distributed initially as a private APK and tested first on Google Pixel.

Unlike iOS, the recommended Android experience is not a replacement keyboard.
[Wispr Flow's documented Android design](https://wisprflow.ai/android) keeps
Gboard or the user's existing keyboard and displays a floating dictation bubble
over eligible text fields. It uses overlay and Accessibility permissions to
insert text without keyboard switching or repeated app handoffs. vocaphone
will follow this product pattern while continuing to use the existing
self-hosted gateway.

The implementation will use supported Android APIs, not assumptions about
Wispr Flow's private code:

- Native Kotlin application.
- Jetpack Compose companion-app UI.
- Lightweight Android View overlay for the floating bubble.
- `AccessibilityService` for detecting editable fields and inserting
  transcripts.
- `AudioRecord` owned by a microphone foreground service.
- Existing HTTP/WebSocket gateway protocol with no breaking server changes.
- Android Keystore encryption for the gateway token.
- No cloud transcription, analytics, or automatic clipboard use.

Google Play publication is deferred, but the app will include honest
accessibility disclosure and consent from the beginning because Play requires
declaration and prominent disclosure for non-accessibility tools using
`AccessibilityService`.
[Google Play policy](https://support.google.com/googleplay/android-developer/answer/10964491?hl=en-GB10)

## Implementation Changes

### Android application foundation

- Add an `android/` Gradle project using Kotlin, Compose, Coroutines, OkHttp,
  DataStore, Room, and WorkManager.
- Use `minSdk 33`, `targetSdk 36`, and a placeholder application ID of
  `com.vocahq.vocaphone`.
- Pin dependencies through a Gradle version catalog and build with the Gradle
  wrapper and an Android-supported LTS JDK.
- Keep Android source independent from Swift code while mirroring the existing
  gateway values, session states, languages, and writing styles.

### Companion app and onboarding

Create a Compose app with:

- Guided setup for microphone, notifications, display-over-other-apps,
  Accessibility service, optional unrestricted battery usage, and gateway
  configuration.
- A separate prominent disclosure explaining that Accessibility access is used
  only to identify the focused editable field and insert user-requested
  transcripts.
- Gateway URL and bearer-token setup supporting:
  - Trusted private-network HTTP such as `http://homelabone.local:8765`.
  - Tailscale/MagicDNS HTTP or HTTPS.
  - Public/VPS deployment over HTTPS.
- Connection test showing reachability, token validity, engine readiness,
  current engine, and streaming support.
- In-app dictation/scratchpad, transcript history, retry, cancellation, and
  deletion.
- Settings matching iOS: automatic insertion, languages, all existing
  writing-style values, audio retention, bubble behavior, and per-app
  exclusions.
- Microphone routing set to Android system automatic by default, with the
  currently routed input displayed while recording. Android exposes the current
  `AudioRecord` route but does not guarantee a permanent manual route.
  [Android audio routing API](https://developer.android.com/reference/android/media/AudioRouting)

### Floating dictation experience

Implement an `AccessibilityService` and `TYPE_APPLICATION_OVERLAY` bubble:

- Show the bubble only when an unlocked, editable, non-sensitive field is
  focused.
- Keep Gboard, Samsung Keyboard, or the user's preferred IME active.
- Provide tap-to-start/tap-to-finish, long-press push-to-talk, cancel, retry,
  draggable position, and temporary snooze.
- Use clear idle, listening, finalizing, transcribing, inserting,
  retryable-error, and permission-repair states.
- Suppress the bubble for password fields, payment/credit-card fields, system
  permission screens, and user-blocked apps.
- Never store or upload surrounding field text; inspect it in memory only when
  insertion requires it.
- Continue active recording across app switches for up to five minutes, warn at
  four minutes, and insert into the eligible field focused when Finish is
  pressed.
- If the screen locks or no safe editable target remains, stop and preserve the
  recording instead of inserting into an uncertain location.
- Keep an ongoing recording notification while the microphone foreground
  service is active.

A short platform spike comes first: prove bubble-triggered microphone capture
on Pixel/API 33 and API 36. Android requires a declared microphone
foreground-service type and runtime microphone permission; newer versions also
restrict background starts and require the overlay to be visible.
[Android foreground-service requirements](https://developer.android.com/develop/background-work/services/fgs/service-types),
[background-start restrictions](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start)

If a tested Android version rejects direct service startup from the overlay,
use the predetermined fallback: a no-animation translucent dictation activity
launched by the explicit bubble tap starts the microphone service while visible,
then closes after capture begins. The user remains in the same target app and
does not manually switch.

### Audio and gateway pipeline

- Capture mono PCM16 through `AudioRecord`, using a buffer sized above the
  platform minimum.
- Write a complete WAV file for recovery and batch fallback.
- Convert PCM16 frames to little-endian float32 chunks for the existing
  authenticated `/v1/stream` protocol.
- Generate one UUID per dictation and preserve idempotency across streaming,
  fallback, retries, and process recreation.
- Prefer streaming when the gateway accepts the WebSocket handshake.
- On unsupported streaming or recoverable WebSocket failure:
  1. `POST /v1/sessions`
  2. `PUT /v1/sessions/{id}/audio`
  3. `POST /v1/sessions/{id}/finish`
- Delete successful audio immediately; retain failed audio only for the same
  bounded retry window used by iOS.
- Use WorkManager only for preserved, user-visible retry work—not for active
  microphone capture.
- Encrypt the bearer token using an AES-GCM key held in Android Keystore; store
  only ciphertext and metadata in app-private storage.
  [Android Keystore](https://developer.android.com/privacy-and-security/keystore)

### Direct insertion and undo

For the focused accessibility node:

- Confirm it is editable, visible, enabled, non-password, and still belongs to
  the foreground window.
- Read the current text and selection into memory.
- Splice the transcript at the selected range.
- Perform `ACTION_SET_TEXT`, then restore the intended cursor with
  `ACTION_SET_SELECTION`.
- Reacquire the focused node immediately before insertion so cross-app
  dictation follows the latest safe target.
- Mark insertion successful only after the accessibility action returns
  success.
- Implement Undo by removing the transcript only when the stored insertion
  range still contains an exact match; disable Undo if the user or target app
  changed that text.
- If a custom editor does not support text actions, retain the transcript in
  history and show an explicit manual-copy action. Never copy automatically.
  Android documents `ACTION_SET_TEXT` as the supported accessibility action for
  editable nodes.
  [Android accessibility action](https://developer.android.com/reference/android/view/accessibility/AccessibilityNodeInfo.AccessibilityAction)

## Interfaces and Compatibility

- Reuse the current gateway without changing its public contract:
  - `GET /health`
  - `GET /v1/models`
  - `POST /v1/sessions`
  - `PUT /v1/sessions/{id}/audio`
  - `POST /v1/sessions/{id}/finish`
  - `DELETE /v1/sessions/{id}`
  - `WebSocket /v1/stream`
- Mirror server values exactly:
  - Styles: `raw`, `clean`, `formal`, `casual`, `very_casual`, `excited`.
  - Languages: `auto`, `en`, `es`, `ar`, `ja`, `ko`, `zh`, `uk`, `vi`.
- Introduce Android-local models for:
  - Gateway configuration and health.
  - Dictation session state.
  - Focused-field identity and selection snapshot.
  - Retryable audio record.
  - Bubble state.
  - Transcript history.
  - Per-app exclusion rules.
- Allow arbitrary user-configured HTTP hosts only because private LAN and
  tailnet gateways require them; show a persistent security warning for
  cleartext and reject public-IP/public-domain HTTP configurations.
- Tailscale requires no embedded SDK: the Android Tailscale VPN handles routing
  transparently.

## Test and Acceptance Plan

### Automated verification

- Unit tests for URL validation, token redaction/encryption, style/language
  serialization, state transitions, WAV generation, PCM conversion, retry
  retention, insertion splicing, safe Undo, and sensitive-field classification.
- MockWebServer tests covering HTTP authentication, idempotency, server errors,
  timeouts, WebSocket streaming, and batch fallback.
- Accessibility tests covering cursor insertion, selected-text replacement,
  stale nodes, unsupported custom editors, app switching, and exact-match Undo.
- Compose tests for onboarding, permission repair, settings, engine status,
  history, and in-app transcription.
- Run `assembleDebug`, unit tests, Android lint, and connected instrumentation
  tests in CI.

### Device matrix

- Emulator/API coverage: Android 13/API 33, Android 16/API 36, and an Android 17
  compatibility image.
- Primary physical gate: Google Pixel running Android 13 or newer.
- Exercise Messages, Gmail, Chrome, Google Keep, notification replies,
  multiline fields, search/address fields, Compose editors, and at least one
  unsupported custom editor.
- Verify Bluetooth/wired microphone routing changes and displayed route.
- Verify LAN HTTP, Tailscale/MagicDNS, and HTTPS gateway configurations.

### Acceptance criteria

- Setup permissions are granted once; ordinary dictation never opens the
  companion app or switches keyboards.
- Bubble appears only for eligible fields and never blocks ordinary typing.
- Recording starts from the bubble, survives switching apps, stops reliably,
  and inserts at the current cursor.
- Styles and languages match iOS and server behavior.
- Streaming and batch-only models both work.
- Failed network/transcription attempts preserve recoverable audio and Retry
  succeeds without duplicate text.
- Password and excluded apps never show the bubble or expose their content.
- Revoked microphone, overlay, accessibility, and notification permissions
  produce actionable repair UI.
- The active engine and current microphone route are visible.
- No audio, transcript, token, or surrounding field text appears in logs.
- The full path is demonstrated against the real vocaphone gateway on a
  physical Pixel before the Android milestone is considered complete.

## Assumptions and Defaults

- The first release is a private APK; no Play Store submission is included.
- Android 13 is the minimum supported version.
- Google Pixel is the baseline; Samsung and other OEM battery-management work
  follows after the stock-Android path passes.
- The bubble architecture is primary; no replacement Android keyboard is
  included.
- The user's existing keyboard remains active.
- Active dictation follows focus across apps and is capped at five minutes.
- Android uses automatic microphone routing and reports the observed active
  route.
- The existing self-hosted gateway remains the only transcription backend.
- Full prototype parity includes app dictation, system-wide bubble dictation,
  history, styles, languages, retry/cancel/undo, health/engine display, and
  microphone status.
- Android 16/API 36 is targeted because Google Play requires new apps and
  updates to target API 36 beginning August 31, 2026.
  [Target API requirements](https://developer.android.com/google/play/requirements/target-sdk)
