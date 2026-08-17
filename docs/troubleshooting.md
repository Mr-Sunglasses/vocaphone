# Troubleshooting

Phone client issues are covered below. Gateway, model, Docker, and network
failures for the transcription server are documented in
[gateway/docs/troubleshooting.md](../gateway/docs/troubleshooting.md) (the
[vocagateway](https://github.com/VocaHQ/vocagateway) submodule).


## Keyboard is missing

Confirm the extension is signed with the containing app, then add vocaphone in
iOS Settings → General → Keyboard → Keyboards. Some secure or specialized fields
intentionally reject third-party keyboards.

## Start does not open vocaphone

Launch vocaphone once directly, confirm the `vocaphone` URL scheme is present,
and retry. If iOS does not open it from the keyboard, open vocaphone manually
within two minutes; it recovers the waiting keyboard request and starts recording.
Automatic return to the original app is not available, so swipe back manually
after recording starts.

## Keyboard never shows recording

Confirm that Settings → General → Keyboard → Keyboards → vocaphone → Allow Full
Access is enabled. iOS provides no link that opens that pane, so the keyboard and
guided setup both print the path rather than offering a button that would land
somewhere else. The app and extension must also use exactly the same
registered App Group. Without Full Access, the keyboard now displays an explicit
warning instead of silently failing to create shared state.

## Microphone is denied

Open iOS Settings → Privacy & Security → Microphone and enable vocaphone. The
keyboard extension itself cannot receive microphone permission.

## The keyboard corrected something I did not want

Press Delete immediately. That restores exactly what you typed, and marks the
word as yours for the rest of that document, so it will not be corrected again.

Tapping your own spelling in the suggestion row — it appears in quotes, on the
left — does the same thing and also teaches the keyboard the word.

If a word keeps coming back, add it under **Settings → Dictation → Custom
words**: those are never corrected away. To make the keyboard forget everything
it has learned, use **Settings → Keyboard → Reset learned words**, which shows
the count before it asks.

Autocorrect never fires on a dictated word, a swiped word, a tapped suggestion,
anything containing a digit or symbol, an all-caps word, or a word shorter than
three letters.

## The suggestion row is empty, or missing

- In a password, passcode, one-time-code or card-number field it is switched off
  deliberately, along with correction, prediction and learning.
- With nothing to suggest, the row shows the language and writing-style pickers
  instead — the keyboard never displays an empty strip.
- While a dictation is recording, processing or waiting to be inserted, that row
  belongs to the dictation state.
- It can be turned off entirely under **Settings → Keyboard → Suggestions**.

Suggestions work with Full Access off. Learned words do not persist without it,
and keyboard haptics do not work at all — iOS gives an extension no route to the
Taptic Engine.

## I cannot find a setting

Settings is grouped by what you are trying to do, in five destinations:

| Destination | What lives there |
| --- | --- |
| **Keyboard** | Height, a live preview, suggestions, autocorrect, prediction, learned words, smart punctuation, emoji suggestions, haptics, swipe typing |
| **Dictation** | Automatic insertion, Quick Dictation, language, writing style, numbers as digits, microphone, recording sounds, custom words |
| **Transcription** | Which source is in use, on-device models, gateway pairing and health |
| **Privacy and permissions** | Microphone status, Full Access explanation and manual path, what is kept |
| **Diagnostics** | Version, redacted export, and clearing the log |

Guided setup is reachable from the bottom of Settings at any time.

## The keyboard is too tall or too short

Open **Settings → Keyboard** and pick Compact, Standard, or Tall. Standard is the
default and matches what earlier versions drew. The change applies the next time
the keyboard appears. Landscape keeps its own compact layout whichever you
choose, because a landscape phone has no height to give away.

## It says "Transcribing" without naming a place

The processing location is written when vocaphone claims a dictation. A session
that predates that field, or one interrupted before the app claimed it, has no
route recorded — so the interface says "Transcribing" rather than guessing. The
next dictation names the place. If it never does, check **Settings →
Transcription**: the selected source must report Ready.

## AirPods are connected but the wrong microphone is used

Open **Settings → Dictation → Input in use**. Use **Automatic** to let
iOS select the combined input/output route, or **iPhone Microphone** to request
the built-in input. Bluetooth input and output routes are linked by iOS, so
changing the microphone can also change where playback is heard while recording.

If the displayed input does not change, stop the current dictation and Quick
Dictation standby, reconnect the accessory, choose the preference again, and
start a new recording.

## Media plays through the receiver after dictation

Update to a build containing the current audio-session handling, then stop any
active recording and disable/re-enable Quick Dictation. With no external audio
route, vocaphone requests the built-in speaker and deactivates its audio session
when standby ends so other apps can restore their normal playback session.

If the orange microphone indicator remains after the ready window should have
expired, force-quit vocaphone once and reopen it. Include the selected input,
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
cd gateway
uv run vocaphone-status
```

For a native VocaMac setup, check that the app is installed, that
`whisperkit-cli` is on `PATH`, and that the model VocaMac selected finished
downloading. An interrupted download leaves the variant folder in place with
empty Core ML components, and the gateway skips it:

```sh
test -d /Applications/VocaMac.app
command -v whisperkit-cli
defaults read com.vocamac.app vocamac.selectedModelSize
du -sh ~/Library/Application\ Support/VocaMac/models/models/argmaxinc/whisperkit-coreml/*
```

A folder of a few kilobytes is an incomplete download — re-download that model
in VocaMac's Models tab.

With `VOCAGATEWAY_ENGINE=whisper.cpp`, also check
`$VOCAGATEWAY_WHISPER_BINARY` and `$VOCAGATEWAY_WHISPER_MODEL`.

For Docker, open Models and download/select SenseVoice Small INT8, Parakeet TDT
INT8, or a faster-whisper Base model. CPU + INT8 applies to faster-whisper;
sherpa entries are already quantized. The container cannot run MLX Audio,
WhisperKit folders, VocaMac, or Handy itself.

## Native Apple silicon transcription is slow

For an MLX model, the active engine should start with `mlx-audio:` and the
dependency card should show MLX Audio available. For WhisperKit, Overview should
report `Metal/Core ML` and the active model should start with `whisperkit:`.
Current WhisperKit builds stay resident behind a random
loopback-only service; after gateway startup, `ps` should show a
`whisperkit-cli serve` child process. Restart the gateway after upgrading
WhisperKit so warmup can start the service. If `serve` is unavailable, vocaphone
deliberately falls back to the slower compatible one-shot CLI.

Use the Test tab's three-run benchmark. It reports warm runs 2 and 3 separately
from the first model-load run. If normalization is small but inference is slow,
try MLX Whisper Turbo 4-bit or a smaller WhisperKit model before changing
network or iPhone settings. MLX requires a native arm64 macOS gateway installed
with `uv sync --extra engines --extra apple`; it is unavailable inside Docker.

## Linux transcription is still slow

Use the Test tab's three-run benchmark, which reports the warm second/third run.
Model load should be zero after the first persistent-engine request. Check:

- the active engine is `sherpa-onnx`, Moonshine, or `faster-whisper`, not the
  per-request `whisper.cpp` CLI
- Precision is INT8 and CPU threads is 0 or no higher than the effective CPU
  allocation shown on Overview
- the container has not been assigned a fractional CPU quota
- Tiny/Base is used before Small/Medium on low-power servers
- for capable hardware, the `native`, `cuda`, or `vulkan` Compose profile is
  running instead of the portable default

Do not run multiple profile services together: they share port 8765 and the
model volume. SenseVoice Small INT8 is the smallest portable multilingual
choice, while Parakeet TDT INT8 covers 25 European languages with punctuation.
Moonshine English Tiny/Small Streaming are fast Linux options;
Tiny prioritizes latency and Small balances speed with accuracy. Other Moonshine
languages use the batch upload path after recording. The app automatically
falls back to that batch path whenever live streaming is unavailable.

## Docker service does not start

Run commands from the directory containing the canonical Compose file:

```sh
cd gateway
docker compose config
docker compose ps
docker compose logs gateway
```

Confirm `gateway/.env` contains a `VOCAGATEWAY_TOKEN` of at least 32 characters and
is not a copy with the placeholder unchanged. A healthy container can still be
not ready until a model is selected; the Docker healthcheck measures liveness.

If port 8765 is already in use, change `VOCAGATEWAY_PUBLISH_PORT` in `.env` and
recreate the service. Tailscale Serve must then point to that same host port.

## Gateway unavailable

Check that the gateway host is awake, reachable, and running. For a Tailscale
deployment, also confirm Tailscale is connected and Serve is active. The
recording should remain on the iPhone for Retry.

For a container deployment, also check `docker compose ps` from `gateway/` and
confirm the `vocagateway_vocagateway-data` volume is still mounted.

## A LAN hostname such as homelabone does not connect

Confirm the app URL includes the scheme and port, for example
`http://homelabone:8765/`, and approve Local Network access in iOS Settings.
Then verify the hostname from another LAN device and check that the gateway is
actually listening beyond loopback.

For Docker, `VOCAGATEWAY_PUBLISH_HOST` must be `0.0.0.0` rather than the secure
loopback default. Recreate the service after changing `gateway/.env`:

```sh
cd gateway
docker compose up --detach
```

Keep the host firewall enabled. Do not use this LAN configuration to expose port
8765 directly to the internet; use an HTTPS reverse proxy for a VPS.

If the pairing QR itself shows no LAN address to pick from (or only shows a
`172.x`/bridge address), that's the same root cause: the container's default
bridge network only exposes its own private interface to address
auto-discovery, never the host's real LAN NIC. On Linux Docker Engine (not
Docker Desktop), set `VOCAGATEWAY_NETWORK_MODE=host` in `gateway/.env` instead so
the container shares the host's network namespace and discovery finds the
`192.168.x.x` address directly. See [deployment.md](deployment.md#trusted-local-network).

## 401 unauthorized

If this device was paired with its own token, open the WebUI Settings tab and
confirm it is still listed under **Paired device tokens** — revoking a token
there immediately rejects it. Otherwise re-run `gateway/scripts/setup-token.sh`,
copy the exact token into vocaphone, and save/test again. Never put the token
in a URL or screenshot.

## 413, 415, or 422

- `413 audio_too_large`: keep recording below two minutes / 25 MB.
- `415 unsupported_audio_type`: use M4A, CAF, or WAV.
- `422 audio_empty`, `invalid_audio`, or `silent_audio`: record again and inspect
  the phone's input route.
- `422 language_unsupported`: the model loaded on your gateway cannot transcribe
  the language selected in the app. Either set the language to Automatic, pick a
  language the model covers, or download a model that covers it — the Models tab
  lists each model's languages. This failure is deliberately not retryable,
  because retrying sends the same language to the same model. For Hindi and other
  South Asian languages, pin the language and use a multilingual Whisper model.

## The transcript came back in the wrong language

Some models decide the language themselves and cannot be pinned to one. Dolphin,
SenseVoice, and Qwen3-ASR all predict the language as part of
decoding, so the language chosen in the app does not constrain them — their model
cards carry an **auto language** badge. On short recordings they can confuse
closely related languages, most often Hindi with Urdu, Marathi, or Nepali.

If you need a guaranteed language, use a Whisper model. `whisper.cpp`,
faster-whisper, WhisperKit, and MLX Whisper are all passed the language
explicitly, so selecting Hindi transcribes Hindi.

Speaking for longer also helps the auto-detecting models: a two-second clip
carries much less evidence of which language it is than a full sentence.

## Some numbers stayed as words

**Write numbers as digits** (Settings → Dictation) converts what it can read as
one number and leaves everything else exactly as dictated. It is deliberately
cautious, because a wrong conversion has to be found and undone by hand:

- A lone "one" stays a word unless a unit follows it, so "no one", "one of them"
  and "one day I'll get to it" are untouched, while "one pm" and "one hour"
  convert.
- Number words that do not add up to a single number are left alone as a group.
  "twenty three" is 23, but "six seven", "seven thirty" and "nineteen eighty
  four" stay as words rather than becoming "6 7", "7 30" and "19 84".
- Ordinals are never rewritten, and neither is the number before one: "the
  twenty first" stays as it is.
- It is English only. Transcripts in other languages pass through untouched.

The setting applies to dictated text on this device, whichever transcription
source produced it, and does not change text typed on the keyboard.

## Transcript did not insert

Return to the same target field and tap Insert. If the keyboard context changed,
vocaphone intentionally refuses automatic insertion to avoid putting private
text in the wrong app. vocaphone uses iOS's document identifier so returning to
the same field still works if the keyboard extension was recreated while the
containing app was open.

If the transcript is visible but Insert appears inactive, tap once in the target
field, switch back to vocaphone keyboard, and wait for the current session card.
Do not start another dictation for the same text: session revisions deliberately
prevent duplicate insertion.

## Finish appears unresponsive

Finish first writes a finalizing revision that the containing app observes. Keep
vocaphone's Quick Dictation session alive, verify the orange microphone
indicator was present, and wait for the Transcribing state. If the gateway is
offline, the keyboard should surface Retry rather than discarding the recording.

Repeated Finish taps are safe, but they do not create a second server session.
When reporting a failure, include the keyboard state shown before and after the
tap, whether vocaphone was open in the background, and the gateway readiness
response—never include the token or a private transcript.

## Reporting a gateway bug

Attach the redacted diagnostics bundle instead of manually describing gateway
state: open the WebUI **Settings** tab and click **Download diagnostics**, or run
`uv run vocaphone-diagnostics` on the gateway host. It contains version, engine
and dependency status, hardware detection, and operational counters, and never
includes the bearer token, recordings, transcripts, or session identifiers.
