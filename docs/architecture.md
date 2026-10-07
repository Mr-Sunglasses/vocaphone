# Architecture

## Component boundary

```text
target app text field
  ↕ UITextDocumentProxy
vocaphone keyboard extension
  ↕ atomic App Group JSON + revision numbers
vocaphone containing app
  ↕ bearer-authenticated HTTP/HTTPS through LAN, VPN, or reverse proxy
FastAPI gateway (VocaHQ/vocagateway submodule at gateway/)
  on macOS or Linux (native or multi-architecture container)
  → bounded temporary audio → FFmpeg mono 16 kHz WAV
  → TranscriptionEngine adapter → VocaMac, Handy, MLX Audio, WhisperKit,
                                  sherpa-onnx, faster-whisper, Moonshine,
                                  or whisper.cpp
```

The gateway implementation and its ops docs live in
[vocagateway](https://github.com/VocaHQ/vocagateway); this repository vendors a
pinned revision under `gateway/`.

The App Group record is the source of truth. Polling is a wake-up strategy, not
the data store. Audio references are opaque filenames; tokens, transcripts, and
absolute paths are never written to ordinary logs.

`SessionRecord.processingLocation` is optional and additive. It is how the
keyboard and the Live Activity name the place transcription is happening without
asking the app, and its absence is a real state — a record written before the
field existed, or a session interrupted before the app claimed it. Every reader
answers that with neutral wording ("Transcribing") rather than guessing a route,
and version-1 records without the field continue to decode unchanged. Nothing on
the gateway wire format changed.

`SessionRecord.targetFingerprint` and `SessionRecord.insertionInterrupted` are
optional and additive in the same way; records without them decode unchanged
and keep the earlier behaviour. The keyboard writes `targetFingerprint` when it
creates a session: the first 64 bits of a SHA-256 over the session ID and the
text within 24 characters either side of the cursor. Only the hash is stored,
never the text, and the session ID salt keeps equal text in two sessions from
producing equal values. A keyboard that adopts the session in a later
appearance — after an app switch or an extension relaunch, where document
identifiers are reissued and cannot be compared — computes the same value for
the field it is in. A mismatch parks the transcript as `targetContextChanged`
("Insert in this field") instead of inserting it automatically, so a dictation
started in one app does not land in another. A field iOS has not answered for
yet is not evidence either way: the transcript waits behind Insert. Two fields
with the same text around the cursor, such as two empty fields, are
indistinguishable, and the transcript follows the cursor there as it did
before. `insertionInterrupted` is described under step 9.

## Recorded request flow

### Gateway work during recording (Android)

On a gateway route, Android keeps writing the authoritative mono 16 kHz PCM16
WAV while a separate IO consumer sends captured frames. A recently checked
batch-only model skips WebSocket negotiation; otherwise the authenticated
socket negotiates incremental transcription. Unsupported or failed negotiation
opens a streamed HTTP PUT to the existing session audio endpoint after readiness
and session creation, while capture continues.

The HTTP body uses unknown-size RIFF/data fields and closes at Finish. The
client requests `?finish=true` so a supporting gateway normalizes the actual
bytes through EOF and returns the batch transcript in the upload response,
removing the separate Finish round trip. An older gateway returns `uploaded`;
the client then calls `/finish` once without replaying the audio. This overlaps
upload with speech for Whisper. A 64 KiB pipe and the existing 96-frame capture queue
(roughly ten seconds) bound transport memory. A stalled writer fails within
eight seconds; dropped frames, an incomplete handshake, or a failed transport
use the complete local file. Cancel stops the dictation's upload child and
aborts the HTTP/socket request. On-device dictation opens no audio transport.
Cancelling it during transcription asks whisper.cpp to abort at its next
encoder or decoder step and deletes the recording, as a cancel while listening
does; it is not recorded as a failure or kept for Retry. Cancelling a Retry
leaves the recording history already holds.

Completed-file uploads and retries encode the capture WAV to temporary mono
16 kHz AAC/M4A at 48 kbps with Android's MediaCodec and MediaMuxer on an IO
worker. The encoder drains its end-of-stream packets before the file is used.
Only a smaller, nonempty copy is uploaded with `audio/mp4`; unsupported WAVs,
unavailable codecs, disk errors, or container overhead retain the original
upload. Temporary copies live in the app's private cache and are removed after
success, failure, or cancellation. The recoverable WAV is deleted only after
the existing successful transcript flow.

The client switches from Uploading to Transcribing when the last body bytes
are sent, before the gateway's response arrives. Upload-completed and
transcription-started diagnostics use that same boundary.

Complete-file fallback and retry uploads request the same combined finalization
and accept the older response too. The HTTP response timeout includes the normal
upload and transcription budgets; the live call deadline also covers the full
capture window plus those budgets. Bounded buffering and eight-second write
deadlines still apply.

On-device WhisperKit transcription uses sequential VAD windows of at most
30 seconds. VocaPhone propagates a failed window rather than accepting a partial
transcript; the existing failure state retains the recording for retry. See
[the model review](local-model-review.md) for the pinned-runtime behavior and
verification limits.

### On-device work during the recording (iOS)

An on-device dictation does most of its decoding before Finish. While the
microphone is open, the app streams the capture, in memory, to a per-dictation
session for the selected engine (`SherpaIncrementalSession` or
`WhisperIncrementalSession`):

- **The model loads when recording starts**, for Whisper as it always has for
  sherpa, so a cold load overlaps the speech instead of following it.
- **A voice activity detector marks the pauses.** Silero VAD (MIT, 644 KB,
  `ios/VocaPhoneApp/Models/silero_vad.onnx`) runs through the sherpa-onnx
  runtime the app already links. It ships in the app bundle, so it works with
  every downloaded model, and it runs on the capture in memory only.
- **Each pause starts an early decode** of everything not yet committed, up to
  0.4 s after the last word. Whisper's decoded windows go into a per-dictation
  cache keyed by their place in the recording, their language and the levelling
  gain; sherpa keeps the one result.
- **At Finish, the trailing pause is trimmed**, but only where the detector
  heard no speech *and* nothing in it rises above the room's own noise floor for
  150 ms or more, so a quiet last word the detector missed is kept. A detector
  that heard no speech at all trims nothing. When nothing was said
  after the last early decode, the trimmed recording is exactly the audio that
  decode read, and its result is used as is: Finish decodes nothing. Anything
  else decodes again, so the early decode can make a dictation faster, never
  different.

Each early decode is also a preview. With Show words while speaking on (off by
default), the app writes the text decoded so far to
`<session>.live` beside the session record — kept apart from the record, like
the meter, so a stale write from the app cannot overwrite the keyboard's Finish
or Cancel — and the keyboard shows the latest words under the waveform while
recording. Saving the record in any state but `recording` deletes the file.

The WAV file is still written and stays authoritative: if the capture queue
refused a chunk, the finish path decodes the file as before. Retries of a
preserved recording also decode the file. `localTranscriptionTimed` in the
diagnostics export records the wait, whether it was decoded early, and how much
was trimmed.

1. The keyboard creates a UUID session and atomically writes `launchingApp`.
2. If a nonexpired Quick Dictation marker exists, the already-running app sees
   the request while its background input is active. Otherwise the keyboard
   opens `vocaphone://dictate?session=<uuid>` after a short fallback delay.
3. The app validates the session, claims it, and resolves which speech-to-text
   route the session will take — `onDevice` or `gateway` — writing that
   `processingLocation` into the record before any audio moves. It then switches
   its persistent audio input from discarding buffers to writing a WAV
   recording, and writes `recording` plus bounded meter updates. The audio graph
   is not rebuilt between dictations.
4. The user manually returns to the original app.
5. While recording on a gateway route, the app negotiates incremental decoding
   on the authenticated WebSocket, unless cached model capabilities rule it
   out. A ready streaming model receives float32 buffers. With a batch-only
   model or failed WebSocket negotiation, the app checks readiness, creates the
   idempotent session, and opens a streamed HTTP PUT to the existing audio
   endpoint. The body is a mono 16 kHz PCM16 WAV with unknown-size RIFF/data
   headers; EOF determines its actual length. URLSession's bound stream holds
   at most 64 KiB and the capture queue holds roughly five seconds. No audio
   transport opens on an on-device route.
6. Finish changes shared state to `finalizing`.
7. Finish closes capture, drains accepted chunks in order, and closes the upload.
   With `?finish=true`, a supporting gateway returns the completed batch
   transcript in that same response. Older gateways return `uploaded`, so the
   client calls `/finish` once without sending the audio again. Whisper receives most
   audio before Finish without needing incremental decoding. A dropped chunk,
   stalled writer, disconnect, unsupported proxy, or incomplete negotiation
   abandons this path and uses the complete local file instead.
   For this fallback, the iPhone encodes its mono 16 kHz WAV to a temporary
   48 kbps AAC/M4A on a worker task. It sends the smaller file with the matching
   content type; failed encoding or container overhead on a short recording
   falls back to WAV. The temporary copy is deleted after the upload attempt,
   while the session WAV remains available for retry. The gateway already
   accepts M4A and normalizes it through FFmpeg before inference.
   Complete-file fallback and retries request the same combined finalization.
   Upload progress switches the session and Live Activity to Transcribing when
   the body is fully sent, before waiting for the transcript. Diagnostics use
   that same boundary. Response timeouts allow both upload and transcription
   budgets, while the live request's total deadline also covers capture.
   Bounded buffering and the
   eight-second write deadline remain in place.
8. The app writes `readyToInsert` and deletes its audio only after success.
9. The keyboard verifies its session context, persists `inserting`, calls
   `insertText`, then persists `inserted` and `completed`.

After Finish, the app can rearm a Quick Dictation window without
tearing down its `AVAudioEngine`. The window length is a preference — 10
minutes, 20 minutes, or "until I close vocaphone", which takes a short lease the
standby heartbeat keeps renewing so a killed process cannot leave a marker that
never expires. The same input tap writes buffers only while a dictation is
active and deliberately discards every standby buffer. The shared availability
file contains only activation and expiry timestamps. It is cleared before active
recording, on expiry, on audio failure, when the user turns the feature off, and
when the Live Activity's Pause button ends the current window. Pausing sets a
flag that the next foreground clears; only the Settings toggle is durable.

Persisting `inserting` before touching the document intentionally favors
avoiding duplicate text if the extension terminates at the worst moment. A
keyboard that later finds a record still `inserting`, more than two seconds old
and not its own, moves it back to `readyToInsert` with `insertionInterrupted`
set. That transcript is offered behind Insert and Cancel with "Insertion may
have been interrupted" and is never inserted automatically, since the text may
already be in the field. It is not parked by its target fingerprint either: the
interrupted insertion may itself have changed the text around the cursor, so
the warning takes precedence over "Insert in this field". `inserting` also expires after 30 seconds, and only
counts as having an active writer within that window, so delete, Delete all and
storage pruning can reclaim a record no keyboard came back for.

## Typing intelligence (iOS keyboard)

Completion, correction and next-word prediction run entirely inside the keyboard
extension. Nothing about them touches the gateway, the App Group session record,
or the network.

```
keystroke ─▶ WordComposer ─▶ TypingEngine ─▶ TypingCandidates ─▶ TypingStripView
                  ▲               │
     documentContextBeforeInput   ├─ UITextChecker (system dictionaries)
        (reconcile only)          ├─ UILexicon (the user's own replacements)
                                  ├─ TypingWordList (shipped, frequency-ordered)
                                  └─ LearnedWords (App Group, capped at 2 000)
```

Three constraints shape the design:

1. **There is no composing region.** `UITextDocumentProxy` has no marked-text
   API, so replacing a word is *n* × `deleteBackward()` plus one `insertText`,
   applied in a single run loop turn and never while a dictation insertion is in
   flight. `WordComposer` is the keyboard's own record of the current word;
   `documentContextBeforeInput` only ever *reconciles* it, because that window is
   bounded and can be `nil` while the keyboard loads.
2. **`UITextChecker` is main-actor.** The SDK marks it `NS_SWIFT_UI_ACTOR`, so it
   cannot be pushed onto a background queue. Keystrokes stay unblocked by
   ordering instead: text is inserted synchronously on touch-up and the
   computation is enqueued as a separate main-actor task, which a generation
   counter cancels if the user has typed on, and a 64-entry LRU cache usually
   skips entirely. `TypingWordList` provides a pure-Swift fallback that *can*
   leave the main actor if device measurement ever demands it.
3. **The extension has a hard memory ceiling.** One checker, one word list, a
   bounded cache and a capped learned-word store. While visible, the keyboard
   checks available process memory every second and before system dictionary
   work. Below 25 MiB of headroom, or on a UIKit memory warning, it releases
   the system checker, suggestion cache, hidden emoji panel and hidden key planes.
   Cleanup is silent and preserves the visible panel, basic typing, bundled
   suggestions and correction undo. Emoji panels are also released when closed
   or when the keyboard disappears; pending catalog delivery is cancelled.
   System dictionary work resumes lazily after five consecutive one-second
   samples with at least 35 MiB available. These are conservative policy
   thresholds, not platform limits or a measured guarantee. iOS can still terminate an
   extension without delivering a warning; these checks cannot guarantee survival.

   Some memory never comes back while the process lives. Every emoji drawn at
   panel size leaves about 50 KB in Core Text's glyph cache, so the panel's grid
   and search show each emoji once and offer skin tones on a long press. A pair
   in two different tones has no row to live in and keeps its own cell. A
   keyboard that leaves the screen at 60% or more of its limit (footprint plus
   available) records `keyboardRecycled` and ends its own process. The next
   field gets a cold start instead of a kill while the user is typing. Session
   state lives in the App Group, so a recreated keyboard adopts it the same way
   it does after a jetsam kill.

The word list, the bigram table, the emoji catalog and the emoji suggestion
table live once at `assets/keyboard/` in the repository root. The iOS keyboard
target references that directory from `project.yml`; the Android build merges
the same directory through `sourceSets` in `app/build.gradle.kts`. Two
hand-maintained copies would drift, and nothing would notice until the
platforms started suggesting different words.

## Android dictation insertion and service lifetime

The Android keyboard inserts a finished transcript through the current
`InputConnection`. It reads at most one character before and after the cursor
or selected range, then uses the shared spacing rule before `commitText`.
These reads happen once per dictation, outside the typing hot path. Context is
used only in memory; unavailable context does not prevent insertion, and
password/sensitive fields remain excluded.

On the `x` flavor (VocaPhoneX) the floating mic replaces the IME as the
dictation surface. `VocaPhoneAccessibilityService` watches focus events, and
`BubbleController` draws an overlay mic (TYPE_APPLICATION_OVERLAY) beside the
screen edge when an eligible editable field gains focus. A tap starts a
dictation whose source is `FLOATING`; the same controller pipeline records,
transcribes on-device or through the gateway, and delivers to
`TextInsertion`, which re-acquires the focused editable node at insertion
time and performs `ACTION_SET_TEXT` on it — cross-app dictation follows the
latest safe target rather than a node that may have died mid-dictation.
Field eligibility (editable, not password/number,
not an excluded package or the app's own UI) is decided once per focus change
in `FieldEligibility`/`BubblePolicy`; password and sensitive fields stay
excluded and the bubble dismisses per typing session or by snooze. Undo and
"inserted" confirmation ride the same `lastInsertion` path the keyboard uses.
Because Android only binds one accessibility service per app, insertion never
goes through an `InputConnection` here — the text arrives as one atomic set,
not keystrokes.

The recording foreground service observes status for display and waits for the
controller's exact dictation job to complete. This keeps it alive through model
loading, inference and insertion, while ensuring a short capture or cancelled
startup removes the notification even when `StateFlow` skips intermediate
phases. A per-start repair signal releases the microphone service when startup
requires permissions, gateway setup or a model download/preparation; the model
progress job can continue without the recording notification. The signal is
separate from UI state so a previous attempt's repair cannot stop a new recording.
The observer also removes the notification on failure or cancellation.

Automatic microphone routing avoids selecting a Bluetooth communication device:
it asks for the phone microphone when a Bluetooth headset is attached. Only an
explicit Bluetooth headset selection enters call mode. Failed or cancelled
capture startup releases audio focus and any communication route it acquired.

## Preview harness (iOS)

Every user-visible state has a `#Preview`, and every preview is built from
`VocaPhoneApp/App/Previews/`. The point is not tidiness: states like "gateway
reachable but token rejected", "model failed its integrity check" and
"transcript ready but the field changed" are expensive enough to reach on a
device that they were never looked at.

Three pieces:

- **`PreviewFixtures`** — canned `SessionRecord`s, `SetupStatus` combinations,
  transcription sources, a transcript library, and named `UserDefaults` stores.
  Stored values go into the *registration* domain, which `UserDefaults` keeps in
  memory, so opening a canvas cannot rewrite the settings of the app installed
  on the same simulator.
- **`PreviewHost` and `PreviewMatrix`** — the environment a screen needs, and the
  four variants every screen has to survive: default, dark, `.accessibility5`,
  and right-to-left.
- **Preview initializers** on `RecordingCoordinator` and `LocalModelManager`.
  Both are live objects whose designated initializers touch audio, the network,
  the keychain and the shared container; the preview ones assign state and stop.
  Both types carry an `isInert` flag that makes their side-effecting entry
  points return early, because a canvas is live — without it a home preview's
  `.task` would overwrite the fixture with the real system state within a frame,
  and Download in a model preview would fetch a gigabyte.

The keyboard's surfaces are all `UIView`s, so they preview through
`KeyboardViewPreview` in the keyboard target, beside the views themselves.

**The `#if DEBUG` boundary is enforced, not assumed.**
`ios/tools/check-preview-isolation.py` fails if a preview-only file has code
outside `#if DEBUG`, or if a preview-only symbol is named from release code. It
runs in `just ios ci` and in the iOS workflow. `just ios release-build` compiles
with DEBUG undefined and is the wider version of the same check.

## Server states

`created → uploaded → transcribing → completed`

Failures move to `failed` while retaining original audio for retry. Repeating
session creation or finishing a completed session returns the same job/result.

## Engine boundary

`TranscriptionEngine` exposes `health()` and `transcribe(path, options)`, while
engines that can identify model files also expose best-effort warmup.
`HandyEngine` can reuse Handy's selected downloaded model, `WhisperKitEngine`
runs Core ML folders through one managed loopback-only WhisperKit service on
Apple silicon, and `WhisperCppEngine` is the portable CLI fallback.
`VocaMacEngine` covers the other optional desktop app: VocaMac exposes no
headless transcription command, so instead of driving the app it reads the model
chosen in VocaMac's preferences, rejects incomplete downloads the way VocaMac's
own asset check does, and hands the Core ML folder and VocaMac's tokenizers to
`WhisperKitEngine`. Both desktop apps are optional and Mac-only — Handy needs
macOS, VocaMac needs Apple silicon — so `app/system.py` holds one table of
per-engine host requirements that drives the WebUI picker contents, the label
shown beside each engine, and the `422` rejection when a host cannot run the
selected engine. The service
keeps the selected model resident and falls back to the one-shot CLI when an
older WhisperKit build cannot serve. `FasterWhisperEngine` owns one persistent
CTranslate2 model and uses CPU INT8 by default. `SherpaOnnxEngine` owns one
portable INT8 recognizer for SenseVoice, Parakeet, GigaAM, Canary, or a
streaming Zipformer model, dispatching on the selected model's catalog
`model_type` for both loading and decoding. `MLXAudioEngine` keeps one
Apple-silicon-native model in unified memory. `MoonshineEngine` owns one
persistent transcriber. Any engine can expose the guarded `/v1/stream` path by
implementing the `StreamingEngine` protocol (`app/models/base.py`):
`supports_streaming`, `streaming_lock`, and `create_stream()` returning an
object with `add_listener`/`add_audio`/`stop`. Currently Moonshine's streaming
architectures and sherpa-onnx's streaming Zipformer model do; `SherpaOnnxEngine`
wraps sherpa-onnx's separate `OnlineRecognizer`/`OnlineStream` API in an adapter
presenting that same surface, so the WebSocket handler itself has no
engine-specific code. Every other model — including every other sherpa-onnx
model — uses the same upload fallback as other batch engines. No
engine-specific field is part of the stable session API
response.

The default Docker image includes OpenBLAS `whisper.cpp`, sherpa-onnx,
faster-whisper, and Moonshine and persists `/data` as a volume. Compose also
provides host-native CPU, NVIDIA CUDA, and Vulkan images. MLX Audio,
WhisperKit, VocaMac, and Handy remain native-macOS-only.

The gateway keeps privacy-safe operational counters in process memory: uptime,
active and queued transcriptions, completed/failed/rejected counts, stage-level
latency, real-time factor, and peak process memory. These counters reset on
restart and never contain audio,
transcripts, session identifiers, or model input text.

Liveness (`/health/live`) is independent of the transcription engine. Readiness
(`/health/ready`) uses a five-second cached engine probe and returns `503` when
the selected model cannot transcribe. Startup schedules a best-effort filesystem
prefetch for the selected model while the HTTP process remains available.

## Deployment boundary

The native macOS gateway can use Apple-platform engines. The container is a
Linux process with persistent CPU engines and optional GPU-specific images;
Docker Desktop cannot pass the macOS MLX, WhisperKit, or Core ML runtime into that
container. Both deployments expose
the same API, WebUI, health semantics, and persistent model-selection behavior.

The canonical container project is `gateway/compose.yaml`. It publishes host
loopback by default, mounts `/data` as the only persistent application volume,
and supplies the bearer token through a Compose secret.
