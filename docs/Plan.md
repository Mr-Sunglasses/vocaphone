# Self-Hosted iPhone Voice Keyboard — Implementation Plan

## 1. Purpose

Build a native iPhone application that provides a system-wide custom keyboard with a microphone button. The user can open any standard iOS text field, select the custom keyboard, dictate, send the audio privately to a transcription model running on their Mac through Tailscale, and insert the returned text directly at the active cursor.

The intended experience is similar to Wispr Flow on iPhone, but the transcription infrastructure is self-hosted and model-independent.

This is not a voice-notes application, a PWA, or a clipboard-only workflow. The primary product is a native iOS keyboard plus its containing iOS application.

## 2. Product requirements

### 2.1 Confirmed requirements

- The client is a native iPhone application.
- The application includes a system-wide custom keyboard extension.
- The keyboard contains a prominent microphone control.
- Audio is captured using the iPhone microphone.
- Transcription runs on local models hosted on the user's Mac.
- The iPhone reaches the Mac privately through Tailscale.
- The result is inserted directly into the currently focused text field.
- The initial transcription engine is based on Whisper or a compatible local implementation.
- The server architecture must allow different local speech-to-text models later.
- Recordings and transcripts must not depend on a third-party transcription service.
- Privacy, recoverability, and explicit failure states are product requirements.

### 2.2 Platform constraint that shapes the architecture

iOS custom keyboard extensions cannot access the microphone, including when the user grants Full Access. Therefore:

- The keyboard extension cannot record audio itself.
- The containing iOS application must request microphone permission and own recording.
- Tapping the microphone in the keyboard must hand off to the containing app when a recording-capable session is not already available.
- The user may need to swipe back to the previous app after recording starts.
- The keyboard and containing app must exchange state through an App Group and supported interprocess mechanisms.
- The keyboard inserts text using `UITextDocumentProxy.insertText(_:)`; it must not require clipboard access for the normal path.

The product must communicate this behavior honestly. It must not promise a seamless transition that iOS does not permit.

## 3. Success definition

Version 0.1 is successful when all of the following work on a physical iPhone:

1. The user installs and enables the custom keyboard.
2. The user grants Full Access and microphone permission during guided onboarding.
3. The user opens a standard text field in another app and selects the keyboard.
4. Tapping the microphone starts a recording through the containing app.
5. The user returns to the original app and sees an active recording state in the keyboard.
6. Tapping Finish stops the recording.
7. Audio reaches the Mac over the user's tailnet.
8. The selected local model returns a transcript.
9. The keyboard inserts that transcript at the current cursor.
10. A failed upload or transcription never silently loses recoverable audio.
11. Audio is deleted automatically after the configured retention period.
12. The entire normal path works without exposing the service to the public internet.

## 4. Non-goals for version 0.1

- App Store launch
- Android support
- macOS or Windows dictation
- Public multi-user SaaS
- A complete replacement for Apple's QWERTY keyboard
- Full autocorrect and next-word prediction
- Real-time word-by-word insertion
- Speaker diarization
- Meeting transcription
- Team accounts
- Public Tailscale Funnel exposure
- Automatic return to the target app when iOS requires a manual swipe
- Editing arbitrary text outside the context exposed to the keyboard

These can be reconsidered only after the recorded-dictation workflow is reliable.

## 5. Assumptions and decisions to confirm

The repository is greenfield. The choices in this section are proposed implementation defaults, not pre-existing constraints.

### 5.1 Proposed defaults

- iOS application language: Swift
- Main application UI: SwiftUI
- Keyboard extension: UIKit `UIInputViewController`, with small reusable SwiftUI views only where proven stable
- Audio capture: `AVAudioEngine`
- Initial recording format: mono PCM in a WAV container written by the persistent audio engine
- Live audio format later: 16 kHz mono PCM chunks or another format verified against the selected engine
- Shared state: App Group container with atomic, versioned JSON records
- Credentials: Keychain access group shared by the app and extension only if the extension needs credentials
- Mac gateway: Python with FastAPI
- Initial transcription adapter: `whisper.cpp`
- Audio conversion: FFmpeg on the Mac
- Private ingress: Tailscale Serve with HTTPS
- Local metadata: SQLite on the Mac and lightweight files/UserDefaults on iPhone
- Dependency management: Swift Package Manager and `uv` for Python

### 5.2 Decisions that must be confirmed during setup

- Product name
- Apple bundle identifier
- App Group identifier
- Apple Developer team and signing arrangement
- The user's physical iPhone model and installed iOS version
- Minimum supported iOS version
- Mac model, Apple Silicon generation, memory, and macOS version
- Whether the Mac is expected to stay awake continuously
- Initial languages: English only, multilingual, or automatic language detection
- Whether mixed Hindi and English is a first-release requirement
- Default Whisper model after measurement
- Whether raw transcripts are kept in history
- Whether audio is deleted immediately or after a short retry window
- Whether a local LLM cleanup pass is enabled by default

Do not silently decide these based only on developer convenience. Record the chosen values in the repository README.

## 6. Proposed repository layout

```text
/
├── README.md
├── docs/Plan.md
├── ios/
│   ├── VocaPhone.xcodeproj
│   ├── VocaPhoneApp/
│   │   ├── App/
│   │   ├── Audio/
│   │   ├── Networking/
│   │   ├── Sessions/
│   │   ├── Shared/
│   │   ├── Settings/
│   │   └── Onboarding/
│   ├── VocaPhoneKeyboard/
│   │   ├── KeyboardViewController.swift
│   │   ├── KeyboardState.swift
│   │   ├── KeyboardLayout/
│   │   └── TextInsertion/
│   ├── VocaPhoneShared/
│   │   ├── SessionRecord.swift
│   │   ├── SharedStore.swift
│   │   ├── IPC.swift
│   │   └── Models.swift
│   ├── VocaPhoneTests/
│   └── VocaPhoneUITests/
├── server/
│   ├── pyproject.toml
│   ├── app/
│   │   ├── main.py
│   │   ├── api/
│   │   ├── auth/
│   │   ├── audio/
│   │   ├── models/
│   │   ├── sessions/
│   │   └── storage/
│   ├── tests/
│   └── scripts/
└── docs/
    ├── device-setup.md
    ├── tailscale.md
    ├── privacy.md
    ├── troubleshooting.md
    └── architecture.md
```

If Codex starts inside an existing repository, it must inspect and adapt to that repository instead of blindly recreating this layout.

## 7. System architecture

### 7.1 Components

#### Containing iOS app

Owns:

- Microphone permission
- `AVAudioSession` configuration
- Audio recording
- Background recording behavior
- Session lifecycle
- Uploading/streaming audio to the Mac
- Local retry queue
- Settings and onboarding
- Live Activity, if used
- Health checks against the Mac
- Secure storage of the server URL and authentication token

#### Keyboard extension

Owns:

- Microphone/start button
- Finish and cancel controls
- Recording/transcription/error state
- Globe/next-keyboard control
- Direct insertion into the active text field
- Undo for the last insertion
- Retry action for recoverable failures
- Optional language/style selector

It does not own microphone capture.

#### Shared iOS module

Owns:

- Versioned session schema
- App Group storage access
- Atomic reads and writes
- IPC notifications
- State transition validation
- Shared error types
- Logging with sensitive-data redaction

#### Mac gateway

Owns:

- Authentication
- Request limits
- Session creation
- Audio upload or streaming
- Temporary audio storage
- Audio normalization
- Transcription adapter selection
- Optional text cleanup
- Result persistence for retry
- Health and model-status endpoints
- Cleanup and retention enforcement

#### Transcription adapter

Defines a stable interface such as:

```python
class TranscriptionEngine(Protocol):
    async def health(self) -> EngineHealth: ...
    async def transcribe(self, audio_path: Path, options: TranscriptionOptions) -> Transcript: ...
```

The API and iOS application must not depend on `whisper.cpp`-specific response fields outside the adapter.

### 7.2 Normal request flow

1. The keyboard creates a UUID session record.
2. The keyboard writes `launchingApp` to the shared App Group.
3. The keyboard asks iOS to open `vocaphone://dictate?session=<uuid>`.
4. The containing app receives the deep link.
5. The app validates the session and activates the microphone.
6. The app writes `recording` and current meter data to shared state.
7. The user swipes back to the previous app.
8. The keyboard reads the shared state and renders the recording UI.
9. The user taps Finish.
10. The keyboard writes a finish command and emits an IPC notification.
11. The app stops recording and writes `uploading`.
12. The app uploads the audio to the Mac gateway.
13. The server transcribes and returns a final result.
14. The app writes `readyToInsert` plus the transcript.
15. The keyboard verifies that the session still belongs to its active context.
16. The keyboard calls `textDocumentProxy.insertText(transcript)`.
17. The keyboard writes `inserted`.
18. The app and server apply their configured retention policy.

### 7.3 Session state machine

```text
idle
  -> launchingApp
  -> awaitingReturn
  -> recording
  -> finalizing
  -> uploading
  -> transcribing
  -> readyToInsert
  -> inserting
  -> inserted
  -> completed
```

Allowed terminal/error states:

```text
canceled
permissionDenied
serverUnavailable
uploadFailedRecoverable
transcriptionFailedRecoverable
transcriptionFailedPermanent
targetContextChanged
expired
```

Every state transition must be explicit and testable. Unknown, stale, or out-of-order updates must be rejected rather than causing duplicate insertion.

### 7.4 Shared session record

The exact encoding may evolve, but the initial record should contain:

```json
{
  "schemaVersion": 1,
  "sessionID": "UUID",
  "revision": 1,
  "state": "recording",
  "createdAt": "ISO-8601",
  "updatedAt": "ISO-8601",
  "sourceDocumentID": "optional keyboard document UUID",
  "language": "auto",
  "style": "raw",
  "meterLevel": 0.0,
  "localAudioReference": "opaque reference or null",
  "serverJobID": "opaque ID or null",
  "transcript": null,
  "error": null
}
```

Use atomic replacement when writing shared files. Never expose absolute private paths or credentials in the record.

### 7.5 IPC strategy

Use the App Group record as the source of truth. IPC notifications are only wake-up hints.

Proposed strategy:

- App Group for durable session records
- Darwin notifications or another supported lightweight notification mechanism for best-effort wakeups
- Short polling by the active keyboard while a session is changing
- Revision numbers to detect updates
- Atomic file replacement to prevent partial reads
- Idempotent commands and transitions

Do not depend on a notification being delivered exactly once. Either process may be suspended or terminated by iOS.

## 8. Mac gateway API

### 8.1 Proposed endpoints

```text
GET    /health
GET    /v1/models
POST   /v1/sessions
PUT    /v1/sessions/{session_id}/audio
POST   /v1/sessions/{session_id}/finish
GET    /v1/sessions/{session_id}
POST   /v1/sessions/{session_id}/retry
DELETE /v1/sessions/{session_id}
```

A WebSocket or streaming endpoint is deferred until the recorded workflow is stable:

```text
WS /v1/sessions/{session_id}/audio
```

### 8.2 API behavior

- All endpoints except `/health` require authentication.
- Session creation returns a server-generated opaque job ID.
- Upload accepts only documented audio MIME types.
- Upload size and duration are limited.
- Repeating a finish or retry request is idempotent.
- Error responses use stable machine-readable codes.
- The server distinguishes offline engine, invalid audio, timeout, overload, and internal failure.
- The server never returns raw filesystem paths.
- Health reports gateway health separately from model readiness.

### 8.3 Authentication

For the personal MVP:

- Generate a high-entropy bearer token during server setup.
- Store it in the iPhone Keychain.
- Keep the service accessible only inside the tailnet.
- Restrict the Mac port to loopback and expose it using Tailscale Serve.
- Apply a restrictive Tailscale policy where practical.
- Never place the token in logs, URLs, App Group JSON, or screenshots.

Tailscale is a network security layer, not a substitute for application authentication.

### 8.4 Audio lifecycle

- Write uploads to a dedicated application data directory.
- Use randomized filenames unrelated to dictated text.
- Track each file by session ID.
- Preserve audio long enough to support the configured retry window.
- Delete successful audio immediately by default for privacy, unless the user explicitly enables history.
- Delete abandoned and failed sessions using a periodic cleanup job.
- Document retention behavior in both the iOS UI and `docs/privacy.md`.

## 9. Transcription and cleanup

### 9.1 Initial engine

Start with `whisper.cpp`, wrapped behind the adapter.

Benchmark at least:

- A small fast English model
- A multilingual model
- The turbo-equivalent option supported by the chosen runtime

Measure on the user's actual Mac:

- Model load time
- Peak memory
- 10-second transcription latency
- 30-second transcription latency
- Accuracy for ordinary speech
- Accuracy for names and technical terms
- Mixed-language accuracy if required

Do not select the default model from published benchmarks alone.

### 9.2 Audio normalization

The server should:

- Validate the uploaded container
- Convert it to the engine's required mono sample rate
- Reject files that exceed limits
- Detect empty or silent recordings
- Preserve the original only during the retry window
- Avoid invoking shell commands with untrusted filenames

### 9.3 Output modes

Version 0.1 should support:

- `raw`: transcription with minimal normalization
- `clean`: conservative punctuation and filler-word cleanup

Later modes may include:

- Message
- Email
- Notes
- Formal
- Casual
- Prompt

If a local LLM performs cleanup:

- It must run on the user's Mac.
- Raw and cleaned text must remain distinguishable.
- Cleanup must not silently invent facts.
- The user must be able to disable it.
- The raw transcript must remain available until insertion succeeds.

## 10. iOS onboarding

The containing app must guide the user through:

1. Confirming that Tailscale is installed and connected
2. Entering or discovering the private Mac endpoint
3. Pairing with the Mac using a token
4. Testing `/health`
5. Requesting microphone permission from the containing app
6. Explaining why keyboard Full Access is needed
7. Opening iOS Keyboard Settings
8. Enabling the VocaPhone keyboard
9. Enabling Full Access
10. Running an in-app recording test
11. Running an external text-field insertion test

The app must explain that Full Access is used for communication with the user's own Mac and shared app state. It should not use Full Access to collect unrelated keystrokes.

## 11. Keyboard behavior

### 11.1 Version 0.1 layout

The first keyboard does not need a complete QWERTY implementation. It should contain:

- Large Start Recording button
- Recording waveform or level indicator
- Finish button
- Cancel button
- Current language
- Current output mode
- Connection/status indicator
- Retry affordance
- Undo last insertion
- Globe/next keyboard button

This keeps the keyboard focused on voice input while the user can switch to Apple's keyboard for manual typing.

### 11.2 Text insertion rules

- Insert only after receiving a final transcript.
- Insert exactly once for a given session ID.
- Preserve intentional line breaks.
- Add leading or trailing whitespace according to nearby text context.
- Do not overwrite selected text in version 0.1 without explicit confirmation.
- If the target document changed during transcription, show the result with an Insert button rather than inserting automatically.
- Retain the last successful transcript until insertion is confirmed.
- Undo must delete only text inserted by the most recent session when the cursor context still matches.

### 11.3 Unsupported fields

The keyboard must handle gracefully:

- Secure text fields
- Phone and number pads
- Apps that disable third-party keyboards
- Custom text editors that provide incomplete proxy behavior
- A target app changing while transcription is pending

These are platform limitations, not server errors.

## 12. Reliability requirements

- No recoverable audio is deleted before a successful transcript or explicit cancellation.
- All network requests have timeouts.
- Retry is idempotent.
- A server restart does not corrupt completed session records.
- The keyboard never inserts a duplicate transcript after reconnecting.
- Stale sessions expire.
- Session records are versioned.
- Shared storage reads tolerate the other process being terminated mid-write.
- If the Mac is sleeping or offline, the UI says so explicitly.
- The user can cancel before upload completes.
- Logs redact audio, transcript text, credentials, and private network details by default.

## 13. Phased implementation

### Phase 0 — Repository and device discovery

Tasks:

- Inspect the repository and any local instructions.
- Record the Xcode, Swift, iOS, macOS, and Python versions.
- Record the physical iPhone and Mac hardware used for validation.
- Confirm Apple signing and App Group capability.
- Confirm Tailscale connectivity from iPhone to Mac.
- Create `README.md` with setup prerequisites and verified commands.
- Add a decision log for unresolved choices.

Exit criteria:

- The iPhone can run a signed containing app and keyboard extension.
- The App Group entitlement works on the physical device.
- The Mac is reachable from the iPhone over Tailscale.

### Phase 1 — Hard feasibility spike

This phase must happen before the transcription server is built.

Tasks:

- Create the containing app.
- Create the custom keyboard extension.
- Add App Group entitlements.
- Add Full Access configuration.
- Implement the keyboard's next-input-mode control.
- Add a Start Recording button.
- Deep-link from the extension to the containing app.
- Request microphone permission in the containing app.
- Start background-capable recording.
- Show a clear “Swipe back to your app” screen.
- Share recording state through the App Group.
- Return to a test field and show the active keyboard state.
- Finish recording from the keyboard.
- Insert a fixed placeholder string with `textDocumentProxy`.

Required physical-device test:

```text
Notes text field
-> VocaPhone keyboard
-> Start
-> containing app records
-> swipe back
-> Finish
-> "The microphone handoff worked." appears at the cursor
```

Exit criteria:

- The complete sequence passes repeatedly on the user's physical iPhone.
- The result is not based only on the Simulator.
- Known OS-specific friction is documented.
- App-to-extension state survives ordinary app switching.

If this gate fails, stop and document the exact platform blocker. Do not hide it by replacing the requirement with clipboard paste or an in-app recorder.

### Phase 2 — Mac transcription gateway

Tasks:

- Scaffold FastAPI application and tests.
- Implement token authentication.
- Implement `/health`.
- Implement session CRUD and idempotency.
- Implement bounded audio upload.
- Implement FFmpeg normalization.
- Implement the transcription adapter protocol.
- Implement `whisper.cpp` adapter.
- Add retention cleanup.
- Add structured, redacted logs.
- Add a launch-at-login mechanism appropriate for macOS.
- Configure Tailscale Serve.
- Document installation and troubleshooting.

Exit criteria:

- A real iPhone recording can be uploaded manually and transcribed.
- The service is reachable over tailnet HTTPS and not publicly exposed.
- Authentication failures are verified.
- Invalid, silent, oversized, and unsupported audio paths are tested.

### Phase 3 — End-to-end recorded dictation

Tasks:

- Connect the containing app to the gateway.
- Add pairing and secure token storage.
- Upload finished recordings.
- Poll or await final results.
- Write the transcript into the shared session.
- Insert it through the keyboard.
- Add retry, cancel, timeout, and offline states.
- Add local pending-session recovery.
- Add immediate-delete and retry-window retention options.

Exit criteria:

- Twenty representative recordings complete end to end.
- No test produces duplicate insertion.
- A network interruption can be retried without re-recording.
- Mac-offline, model-offline, and authentication errors are distinguishable.

### Phase 4 — Product-quality keyboard

Tasks:

- Polish the recording UI.
- Add waveform/metering.
- Add language and output-mode controls.
- Add undo.
- Add safe spacing and punctuation insertion.
- Add session history in the containing app.
- Add diagnostics export with sensitive-data redaction.
- Add accessibility labels, Dynamic Type support, VoiceOver checks, and adequate touch targets.
- Test common target applications.

Exit criteria:

- Notes, Messages, Mail, Safari, WhatsApp, Slack, and ChatGPT standard text fields are tested where installed.
- Secure and unsupported fields fail gracefully.
- Onboarding can be completed without developer intervention.

### Phase 5 — Streaming dictation

Begin only after Phase 4 is stable.

Tasks:

- Stream bounded audio chunks.
- Add voice activity detection.
- Return provisional and final segments.
- Reconcile overlapping windows.
- Use marked text for provisional output only if it behaves safely across target apps.
- Recover from brief network interruptions.
- Measure battery use and thermal impact.

Exit criteria:

- Final text is never duplicated or reordered.
- Partial text does not corrupt the target field.
- Streaming is measurably faster than recorded mode.
- Recorded mode remains available as a reliable fallback.

### Phase 6 — Optional full keyboard

Possible scope:

- QWERTY layout
- Shift and caps lock
- Numeric and symbol layouts
- Delete repeat
- Spacebar trackpad behavior
- Haptics
- Key popovers
- Autocorrection
- Suggestions
- Multilingual layouts

Treat this as a separate substantial workstream. Do not delay the voice MVP for it.

## 14. Testing strategy

### 14.1 iOS unit tests

- Session-state transition validation
- Versioned shared-record decoding
- Atomic store behavior
- Duplicate-result suppression
- Safe spacing rules
- Error-code mapping
- Retry idempotency
- Credential redaction

### 14.2 Server unit tests

- Authentication
- Session creation and expiry
- Upload limits
- MIME and file validation
- Adapter error mapping
- Retention cleanup
- Idempotent finish/retry
- Transcript schema
- Log redaction

### 14.3 Integration tests

- Recorded fixture to gateway to transcript
- Server unavailable
- Model unavailable
- Slow transcription
- Interrupted upload
- Retried upload
- Silent audio
- Unsupported format
- Token rejection
- Server restart during a pending job

### 14.4 Physical iPhone tests

The following cannot be signed off using only automated or Simulator tests:

- Keyboard installation and Full Access
- Microphone permission handoff
- Deep-link launch from keyboard
- Manual return to target app
- Background recording
- App Group state synchronization
- Direct insertion into third-party text fields
- Low Power Mode behavior
- Screen-lock behavior
- Phone-call and Siri interruption
- Bluetooth connect/disconnect
- Tailscale over Wi-Fi and cellular
- App termination and recovery

### 14.5 Performance targets

Initial targets, to be revised after measurement:

- Keyboard appears without visible blocking work.
- Start action gives feedback within 300 ms, excluding the required app transition.
- Session state becomes visible after returning within 500 ms.
- A 10-second recording reaches final inserted text within 5 seconds after Finish on the target Mac/model.
- Gateway health check completes within 2 seconds on a healthy tailnet.
- No unbounded audio or transcript data remains in extension memory.

## 15. Security and privacy

- Tailnet-only service exposure
- HTTPS through Tailscale Serve
- Independent bearer-token authentication
- Keychain credential storage
- No credentials in shared JSON
- No public Funnel
- No analytics in version 0.1
- No collection of unrelated keystrokes
- No transcript or audio in ordinary logs
- Configurable transcript history
- Audio deletion by default
- Explicit Full Access explanation
- Local-only cleanup model
- Maximum recording duration and upload size
- Dependency and package audit in CI
- Threat model documented before any public distribution

## 16. Operational requirements

- The Mac service starts automatically after login.
- The model reports readiness separately from gateway readiness.
- The UI detects a sleeping or unreachable Mac.
- Setup documents how to keep the Mac available safely.
- The server provides a local status command or page.
- Tailscale Serve configuration is inspectable and reversible.
- The service binds to loopback unless a documented alternative is required.
- Model downloads and storage locations are documented.
- Backups must exclude temporary audio by default.

## 17. Documentation requirements

Maintain:

- Root `README.md` with verified setup and development commands
- `docs/device-setup.md` for signing, keyboard enablement, permissions, and physical-device testing
- `docs/tailscale.md` for private connectivity and Serve configuration
- `docs/privacy.md` for data flow, retention, and Full Access
- `docs/troubleshooting.md` for common iOS, Tailscale, audio, and model failures
- `docs/architecture.md` for the session state machine and component boundaries

Any command documented as working must have been run successfully in the applicable environment, or clearly labeled as unverified.

## 18. CI and quality gates

Proposed checks:

- Swift build and unit tests
- Swift formatting/linting if introduced
- Python formatting and linting
- Python type checking
- Server unit and integration tests
- Dependency vulnerability audit
- Secret scanning
- No generated credentials or audio fixtures containing private speech
- Documentation link validation

Physical-device acceptance remains a separate manual gate.

## 19. Risks and mitigations

### iOS terminates or suspends the containing app

Mitigation:

- Keep durable session state.
- Preserve recoverable audio.
- Design every command to be idempotent.
- Test Low Power Mode and memory pressure.
- Show a restart/retry path instead of hanging.

### App-to-keyboard handoff differs by iOS version

Mitigation:

- Test the user's actual OS first.
- Keep the handoff isolated behind a small coordinator.
- Document manual swipe behavior.
- Do not depend on undocumented automatic switching.

### Shared-state races cause duplicate insertion

Mitigation:

- Use UUIDs, revisions, atomic writes, transition validation, and an inserted marker.
- Verify target document context before automatic insertion.

### Mac is sleeping or unavailable

Mitigation:

- Preflight `/health`.
- Provide an explicit offline state.
- Queue locally when safe.
- Document availability expectations.

### Model latency is too high

Mitigation:

- Benchmark several models on actual hardware.
- Load the model persistently.
- Add streaming only after correctness.
- Provide a fast-model option.

### Full Access reduces user trust

Mitigation:

- Explain exactly why it is needed.
- Keep processing on the user's tailnet and Mac.
- Do not collect general keyboard input.
- Publish the data-flow documentation.

### Building a complete keyboard expands scope

Mitigation:

- Ship the voice control keyboard first.
- Use the globe button for switching to Apple's keyboard.
- Treat QWERTY parity as a later project.

## 20. Codex execution instructions

When implementing this plan, Codex should:

1. Inspect the repository, local instructions, installed tools, and dirty worktree before editing.
2. Create or update `README.md` with verified commands and clearly marked prerequisites.
3. Record assumptions and unresolved decisions instead of presenting them as confirmed.
4. Implement Phase 0 and Phase 1 before building the Mac gateway.
5. Keep changes scoped to the current phase.
6. Add tests with each component.
7. Never claim the microphone handoff works until it passes on a physical iPhone.
8. Never replace direct keyboard insertion with clipboard paste without explicit approval.
9. Never expose the service publicly.
10. Never commit, publish, deploy, or submit to the App Store without explicit permission.
11. Preserve unrelated user changes in an existing worktree.
12. Report blockers with the exact failing state and evidence.

At the end of every phase, Codex should provide:

- What was implemented
- What was actually verified
- What still requires a physical device or user action
- Known limitations
- Exact next phase

## 21. Version 0.1 definition of done

Version 0.1 is done only when:

- The native containing app and keyboard extension install on the user's iPhone.
- Onboarding guides microphone permission, keyboard enablement, and Full Access.
- The keyboard starts a recording through the containing app.
- The user can return to the original text field while recording.
- The keyboard can finish or cancel the recording.
- Audio is delivered privately to the Mac through Tailscale.
- A local model produces a transcript.
- The transcript is inserted directly at the current cursor.
- Retry preserves audio after a transient network or server failure.
- Duplicate insertion is prevented.
- Audio retention matches the documented setting.
- Common target apps have been tested.
- Unsupported fields fail gracefully.
- Server and iOS tests pass.
- Setup, privacy, architecture, and troubleshooting documentation are current.
- Remaining limitations, including iOS app-switch friction, are stated plainly.

## 22. Research references

- Apple, Custom Keyboard extensions: <https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard>
- Apple, Configuring open access: <https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard>
- Apple, Text interactions and insertion: <https://developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards>
- Apple, App Groups: <https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.application-groups>
- Apple, Extension URL opening: <https://developer.apple.com/documentation/foundation/nsextensioncontext>
- Apple, Audio recording: <https://developer.apple.com/documentation/avfaudio/avaudioengine>
- Tailscale Serve: <https://tailscale.com/docs/reference/tailscale-cli/serve>
- OpenAI Whisper: <https://github.com/openai/whisper>
- whisper.cpp: <https://github.com/ggml-org/whisper.cpp>
- Wispr Flow iPhone keyboard behavior: <https://docs.wisprflow.ai/articles/7453988911-set-up-the-flow-keyboard-on-iphone>
- Wispr Flow iOS session behavior: <https://docs.wisprflow.ai/articles/3634682593-why-the-orange-dot-or-mic-indicator-stays-on-after-dictating-ios>
