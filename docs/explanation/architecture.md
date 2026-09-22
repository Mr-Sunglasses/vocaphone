---
title: How VocaPhone works
description: Understand the recording, keyboard, gateway, engine, and insertion boundaries.
---

# How VocaPhone works

This page explains the system boundary and the path a dictation takes from a
text field to a transcript. Use it when you need context before changing code
or diagnosing a cross-platform failure.

## Component boundary

```mermaid
flowchart LR
  field[Target app text field]
  keyboard[VocaPhone keyboard]
  app[Containing app or foreground service]
  local[On-device speech model]
  gateway[Self-hosted VocaGateway]
  normalize[Bounded audio and FFmpeg normalization]
  engine[TranscriptionEngine adapter]
  result[Transcript]

  field <-->|insert at cursor| keyboard
  keyboard <-->|App Group session state| app
  app --> local
  app -. authenticated HTTP or WebSocket .-> gateway
  gateway --> normalize --> engine --> result
  local --> result
  result --> app --> keyboard
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

## Recorded request flow

The dictation lifecycle is easier to reason about as a message sequence. The
same session UUID is used across the phone handoff, streaming or batch request,
retry, and insertion.

```mermaid
sequenceDiagram
  participant Field as Text field
  participant Keyboard as VocaPhone keyboard
  participant State as App Group or shared state
  participant App as Containing app or service
  participant Model as On-device model
  participant Gateway as Self-hosted gateway

  Field->>Keyboard: User taps Dictate
  Keyboard->>State: Write UUID and launchingApp
  alt iOS app is already ready
    State-->>App: Quick Dictation marker wakes app
  else Normal handoff
    Keyboard->>App: Open dictate URL or launch app
  end
  App->>State: Claim session and set processingLocation
  App->>App: Capture bounded PCM16 WAV
  Field-->>Keyboard: User returns to the text field
  Keyboard->>State: Finish request
  alt On-device transcription
    App->>Model: Transcribe local recording or stream
    Model-->>App: Transcript
  else Gateway transcription
    App->>Gateway: Authenticated stream or idempotent upload
    Gateway-->>App: Transcript or retryable error
  end
  App->>State: Write readyToInsert and remove audio on success
  Keyboard->>State: Write inserting
  Keyboard->>Field: insertText(transcript)
  Keyboard->>State: Write inserted and completed
```

| Stage | Owner | Boundary |
| --- | --- | --- |
| Session launch | Keyboard | Creates a UUID and atomically writes `launchingApp`. |
| App claim | Containing app or service | Validates the record and writes `processingLocation` before audio moves. |
| Recording | Phone audio owner | Writes a bounded WAV while publishing meter state; standby buffers are discarded. |
| Transcription | On-device model or configured gateway | Streaming is attempted when supported; batch upload is the idempotent fallback. |
| Handoff | Shared session state | Writes `readyToInsert` only after a transcript is available and successful audio can be deleted. |
| Insertion | Keyboard | Persists `inserting` before calling `insertText` to reduce duplicate text after termination. |

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
avoiding duplicate text if the extension terminates at the worst moment.

## Typing intelligence (iOS keyboard)

Completion, correction and next-word prediction run entirely inside the keyboard
extension. Nothing about them touches the gateway, the App Group session record,
or the network.

```mermaid
flowchart LR
  touch[Keystroke] --> composer[WordComposer]
  composer --> engine[TypingEngine]
  engine --> candidates[TypingCandidates]
  candidates --> strip[TypingStripView]
  context[documentContextBeforeInput] -. reconcile only .-> composer
  checker[UITextChecker]
  lexicon[UILexicon]
  wordlist[TypingWordList]
  learned[LearnedWords, capped at 2,000]
  checker --> engine
  lexicon --> engine
  wordlist --> engine
  learned --> engine
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

The word list, the bigram table, the emoji catalog and the emoji suggestion
table live once at `assets/keyboard/` in the repository root. The iOS keyboard
target references that directory from `project.yml`; the Android build merges
the same directory through `sourceSets` in `app/build.gradle.kts`. Two
hand-maintained copies would drift, and nothing would notice until the
platforms started suggesting different words.

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

```mermaid
stateDiagram-v2
  [*] --> created
  created --> uploaded: audio accepted
  uploaded --> transcribing: engine starts
  transcribing --> completed: transcript ready
  created --> failed: validation or upload error
  uploaded --> failed: normalization error
  transcribing --> failed: engine error
  failed --> uploaded: retry same session
  completed --> completed: idempotent finish
  completed --> [*]
```

Failures retain the original audio for the configured retry window. Repeating
session creation or finishing a completed session returns the same job or
result, so a client can retry without creating a duplicate transcription.

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

```mermaid
flowchart TD
  phone[Phone app] -->|private LAN, VPN, or HTTPS| ingress[Gateway ingress]
  ingress --> native[Native macOS or Linux gateway]
  ingress --> container[Docker Compose gateway]
  native --> nativeEngine[Host-native engines]
  container --> portable[Portable CPU or GPU engines]
  nativeEngine --> response[Same API and health semantics]
  portable --> response
```

The native macOS gateway can use Apple-platform engines. The container is a
Linux process with persistent CPU engines and optional GPU-specific images;
Docker Desktop cannot pass the macOS MLX, WhisperKit, or Core ML runtime into that
container. Both deployments expose
the same API, WebUI, health semantics, and persistent model-selection behavior.

The canonical container project is `gateway/compose.yaml`. It publishes host
loopback by default, mounts `/data` as the only persistent application volume,
and supplies the bearer token through a Compose secret.
