# Troubleshooting

## Keyboard is missing

Confirm the extension is signed with the containing app, then add Local Flow in
iOS Settings → General → Keyboard → Keyboards. Some secure or specialized fields
intentionally reject third-party keyboards.

## Start does not open Local Flow

Launch Local Flow once directly, confirm the `localflow` URL scheme is present,
and retry. If iOS does not open it from the keyboard, open Local Flow manually
within two minutes; it recovers the waiting keyboard request and starts recording.
Automatic return to the original app is not available, so swipe back manually
after recording starts.

## Keyboard never shows recording

Confirm that Settings → General → Keyboard → Keyboards → Local Flow has Allow
Full Access enabled. The app and extension must also use exactly the same
registered App Group. Without Full Access, the keyboard now displays an explicit
warning instead of silently failing to create shared state.

## Microphone is denied

Open iOS Settings → Privacy & Security → Microphone and enable Local Flow. The
keyboard extension itself cannot receive microphone permission.

## Gateway reachable, model not ready

`/health` distinguishes these states. Check:

```sh
test -x /Applications/Handy.app/Contents/MacOS/handy
/Applications/Handy.app/Contents/MacOS/handy --list-models --json
cd server
uv run localflow-status
```

With `LOCALFLOW_ENGINE=whisper.cpp`, also check
`$LOCALFLOW_WHISPER_BINARY` and `$LOCALFLOW_WHISPER_MODEL`.

## Mac unavailable

Check that the Mac is awake, Tailscale is connected, Serve is active, and the
gateway process is running. The recording should remain on the iPhone for Retry.

## 401 unauthorized

Re-run `server/scripts/setup-token.sh`, copy the exact token into Local Flow, and
save/test again. Never put the token in a URL or screenshot.

## 413, 415, or 422

- `413 audio_too_large`: keep recording below two minutes / 25 MB.
- `415 unsupported_audio_type`: use M4A, CAF, or WAV.
- `422 audio_empty`, `invalid_audio`, or `silent_audio`: record again and inspect
  the phone's input route.

## Transcript did not insert

Return to the same target field and tap Insert. If the keyboard context changed,
Local Flow intentionally refuses automatic insertion to avoid putting private
text in the wrong app. Local Flow uses iOS's document identifier so returning to
the same field still works if the keyboard extension was recreated while the
containing app was open.
