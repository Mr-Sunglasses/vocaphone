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

## AirPods are connected but the wrong microphone is used

Open Local Flow and check **Microphone → Input in use**. Use **Automatic** to let
iOS select the combined input/output route, or **iPhone Microphone** to request
the built-in input. Bluetooth input and output routes are linked by iOS, so
changing the microphone can also change where playback is heard while recording.

If the displayed input does not change, stop the current dictation and Quick
Dictation standby, reconnect the accessory, choose the preference again, and
start a new recording.

## Media plays through the receiver after dictation

Update to a build containing the current audio-session handling, then stop any
active recording and disable/re-enable Quick Dictation. With no external audio
route, Local Flow requests the built-in speaker and deactivates its audio session
when standby ends so other apps can restore their normal playback session.

If the orange microphone indicator remains after the ready window should have
expired, force-quit Local Flow once and reopen it. Include the selected input,
connected accessories, and whether Quick Dictation was Ready in a bug report.

## Gateway reachable, model not ready

Liveness and readiness distinguish these states:

```sh
curl --fail http://127.0.0.1:8765/health/live
curl --include http://127.0.0.1:8765/health/ready
```

If liveness is `200` but readiness is `503`, inspect the selected model in the
WebUI. For a native Handy setup, also check:

```sh
test -x /Applications/Handy.app/Contents/MacOS/handy
/Applications/Handy.app/Contents/MacOS/handy --list-models --json
cd server
uv run localflow-status
```

With `LOCALFLOW_ENGINE=whisper.cpp`, also check
`$LOCALFLOW_WHISPER_BINARY` and `$LOCALFLOW_WHISPER_MODEL`.

For Docker, open the Models tab and download/select a `whisper.cpp` model. The
container cannot run WhisperKit folders or Handy's ONNX-only model families.

## Docker service does not start

Run commands from the directory containing the canonical Compose file:

```sh
cd server
docker compose config
docker compose ps
docker compose logs gateway
```

Confirm `server/.env` contains a `LOCALFLOW_TOKEN` of at least 32 characters and
is not a copy with the placeholder unchanged. A healthy container can still be
not ready until a model is selected; the Docker healthcheck measures liveness.

If port 8765 is already in use, change `LOCALFLOW_PUBLISH_PORT` in `.env` and
recreate the service. Tailscale Serve must then point to that same host port.

## Mac unavailable

Check that the Mac is awake, Tailscale is connected, Serve is active, and the
gateway process is running. The recording should remain on the iPhone for Retry.

For a container deployment, also check `docker compose ps` from `server/` and
confirm the `localflow_localflow-data` volume is still mounted.

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

If the transcript is visible but Insert appears inactive, tap once in the target
field, switch back to Local Flow keyboard, and wait for the current session card.
Do not start another dictation for the same text: session revisions deliberately
prevent duplicate insertion.

## Finish appears unresponsive

Finish first writes a finalizing revision that the containing app observes. Keep
Local Flow's Quick Dictation session alive, verify the orange microphone
indicator was present, and wait for the Transcribing state. If the gateway is
offline, the keyboard should surface Retry rather than discarding the recording.

Repeated Finish taps are safe, but they do not create a second server session.
When reporting a failure, include the keyboard state shown before and after the
tap, whether Local Flow was open in the background, and the gateway readiness
response—never include the token or a private transcript.
