# Architecture

## Component boundary

```text
target app text field
  ↕ UITextDocumentProxy
Local Flow keyboard extension
  ↕ atomic App Group JSON + revision numbers
Local Flow containing app
  ↕ bearer-authenticated HTTPS through Tailscale Serve
FastAPI gateway on Mac (127.0.0.1)
  → bounded temporary audio → FFmpeg mono 16 kHz WAV
  → TranscriptionEngine adapter → Handy CLI or whisper.cpp
```

The App Group record is the source of truth. Polling is a wake-up strategy, not
the data store. Audio references are opaque filenames; tokens, transcripts, and
absolute paths are never written to ordinary logs.

## Recorded request flow

1. The keyboard creates a UUID session and atomically writes `launchingApp`.
2. If a nonexpired Quick Dictation marker exists, the already-running app sees
   the request while its background input is active. Otherwise the keyboard
   opens `localflow://dictate?session=<uuid>` after a short fallback delay.
3. The app validates the session, switches its persistent audio input from
   discarding buffers to writing a WAV recording, and writes `recording` plus
   bounded meter updates. The audio graph is not rebuilt between dictations.
4. The user manually returns to the original app.
5. Finish changes shared state to `finalizing`.
6. The still-recording containing app notices the revision, stops, creates an
   idempotent server session, uploads audio, and asks the gateway to finish.
7. The gateway normalizes and transcribes behind the stable engine adapter.
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

`TranscriptionEngine` exposes `health()` and `transcribe(path, options)`.
`HandyEngine` is selected automatically when Handy is installed and reuses its
selected downloaded model. `WhisperCppEngine` remains the standalone fallback.
No engine-specific field is part of the session API response.
