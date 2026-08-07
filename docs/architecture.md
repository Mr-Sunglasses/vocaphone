# Architecture

## Component boundary

```text
target app text field
  ↕ UITextDocumentProxy
vocaphone keyboard extension
  ↕ atomic App Group JSON + revision numbers
vocaphone containing app
  ↕ bearer-authenticated HTTP/HTTPS through LAN, VPN, or reverse proxy
FastAPI gateway on macOS or Linux (native or multi-architecture container)
  → bounded temporary audio → FFmpeg mono 16 kHz WAV
  → TranscriptionEngine adapter → VocaMac, Handy, MLX Audio, WhisperKit,
                                  sherpa-onnx, faster-whisper, Moonshine,
                                  or whisper.cpp
```

The App Group record is the source of truth. Polling is a wake-up strategy, not
the data store. Audio references are opaque filenames; tokens, transcripts, and
absolute paths are never written to ordinary logs.

## Recorded request flow

1. The keyboard creates a UUID session and atomically writes `launchingApp`.
2. If a nonexpired Quick Dictation marker exists, the already-running app sees
   the request while its background input is active. Otherwise the keyboard
   opens `vocaphone://dictate?session=<uuid>` after a short fallback delay.
3. The app validates the session, switches its persistent audio input from
   discarding buffers to writing a WAV recording, and writes `recording` plus
   bounded meter updates. The audio graph is not rebuilt between dictations.
4. The user manually returns to the original app.
5. Finish changes shared state to `finalizing`.
6. The app negotiates streaming support on the authenticated WebSocket itself,
   avoiding a separate health round trip. With a ready Moonshine engine, copied
   float32 buffers reach the streaming endpoint while the app still writes the
   complete WAV. Batch-only engines receive a structured unsupported response.
7. The app stops recording and uses the stream result when available. Otherwise
   it creates the idempotent session and runs the normal upload/batch flow.
8. The app writes `readyToInsert` and deletes its audio only after success.
9. The keyboard verifies its session context, persists `inserting`, calls
   `insertText`, then persists `inserted` and `completed`.

After Finish, the app can rearm a 10-minute Quick Dictation window without
tearing down its `AVAudioEngine`. The same input tap writes buffers only while a
dictation is active and deliberately discards every standby buffer. The shared
availability file contains only activation and expiry timestamps. It is cleared
before active recording, on expiry, on audio failure, or when the user turns the
feature off.

Persisting `inserting` before touching the document intentionally favors
avoiding duplicate text if the extension terminates at the worst moment.

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

The canonical container project is `server/compose.yaml`. It publishes host
loopback by default, mounts `/data` as the only persistent application volume,
and supplies the bearer token through a Compose secret.
