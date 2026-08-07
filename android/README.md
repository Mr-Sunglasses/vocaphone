# vocaphone for Android

A native Android dictation client for the same self-hosted vocaphone gateway the
iPhone app uses. Unlike iOS, it does **not** replace your keyboard. Gboard,
Samsung Keyboard or whatever you already use stays active, and vocaphone shows a
floating bubble over eligible text fields, inserting the transcript at your
cursor when you finish.

Distributed as a private APK. Google Play publication is deferred, but the
accessibility disclosure and consent Play requires are present from the start.

> Package name and application ID have been updated to `com.vocahq.vocaphone`; the APK
> output is `vocaphone-debug.apk`.

## Requirements

- Android 13 (API 33) or newer. Google Pixel is the baseline device.
- A reachable vocaphone gateway. See the [root README](../README.md).
- To build: JDK 17+ (the JDK bundled with Android Studio works) and the Android
  SDK. Everything else is pinned in `gradle/libs.versions.toml` and fetched by
  the Gradle wrapper.

## Build

```sh
cd android
# macOS default SDK path; on Linux Android Studio usually uses $HOME/Android/Sdk
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/vocaphone-debug.apk
```

Verification the same way CI should run it:

```sh
./gradlew assembleDebug testDebugUnitTest lintDebug
```

`compileSdk` is 37 because current AndroidX releases require it. `targetSdk`
stays at 36, which is what Play requires from 31 August 2026.

## First run

The companion app walks through setup and re-checks it on every resume, so a
permission revoked later shows up as an actionable repair prompt rather than a
silent failure.

1. **Microphone** — recording only while you are dictating.
2. **Notifications** — the ongoing recording notification Android requires for a
   microphone foreground service.
3. **Display over other apps** — draws the bubble.
4. **Accessibility service** — see the disclosure below.
5. **Unrestricted battery usage** (optional) — stops Android ending a long
   dictation early.
6. **Gateway address and token** — either **Scan QR code** against the gateway
   WebUI Overview pairing card, or paste the URL and bearer token, then
   **Test connection**, which reports reachability, token validity, the active
   engine, whether it is ready, and whether it supports streaming.

## How accessibility access is used

vocaphone is not an accessibility tool, so it states plainly what it does with
the service, and the app asks for separate consent before the checklist step:

- To tell whether the focused text field can be dictated into, so the bubble
  appears only where it is useful.
- To insert the transcript you asked for at your cursor, and to undo it.

Field contents are read **only** at the moment of insertion, and only in memory.
They are never stored, logged, or sent anywhere — not to the gateway. The bubble
stays hidden in password and payment fields, on system permission screens, and in
any app you exclude in Settings.

## Dictating

- **Tap** the bubble to start, **tap again** to finish.
- **Hold** it for push-to-talk; release to finish.
- **Drag** it anywhere on screen.
- **Long-press the ✕** to snooze the bubble for 15 minutes.
- Recording follows you across apps, warns a minute before the five-minute cap,
  and stops there. The transcript goes into whichever eligible field is focused
  when you finish.
- If the screen locks or no safe editable target remains, nothing is inserted —
  the transcript waits in History instead of landing somewhere uncertain.
- **Undo** removes an insertion only while the exact text is still where it was
  written. If you or the app edited it, Undo is disabled rather than destructive.

## Choosing a microphone

**Settings → Microphone** picks which input dictation asks for: Automatic, or the
phone, wired headset, Bluetooth headset, or USB microphone. Options with no
matching hardware connected stay visible but greyed out, and the row locks while
a dictation is running — the input is chosen when the recorder is built.

A category is stored rather than a device id, because Android issues a fresh id
on every reconnect. Selecting a Bluetooth headset puts it into call mode, which
is the only way Android exposes its microphone, so music playback drops in
quality while you dictate. Android has the final say on routing: **Input in use**
reports the route capture actually got, not the one that was requested.

## Gateway addresses

The app talks only to the gateway you configure, over the unchanged public
contract: `GET /health`, `GET /v1/models`, `POST /v1/sessions`,
`PUT /v1/sessions/{id}/audio`, `POST /v1/sessions/{id}/finish`,
`DELETE /v1/sessions/{id}`, and the `/v1/stream` WebSocket.

| Address | Scheme |
| --- | --- |
| `http://homelabone.local:8765` | Plain HTTP allowed (mDNS) |
| `http://192.168.1.20:8765` | Plain HTTP allowed (RFC 1918) |
| `http://homelabone.tail1234.ts.net:8765` | Plain HTTP allowed (tailnet) |
| `https://flow.example.com` | Required for anything public |

Plain HTTP is refused for hosts reachable from the internet, and a persistent
warning is shown while a cleartext gateway is configured. Tailscale needs no SDK:
the Android Tailscale VPN routes the traffic transparently.

## What happens to your audio

- Captured as 16 kHz mono PCM16 and written to a complete WAV in app-private
  storage while recording.
- Streamed to `/v1/stream` as little-endian float32 frames when the active engine
  supports it; otherwise, and after a recoverable stream failure, the WAV goes
  through the batch endpoints. One session UUID is reused throughout, so retries
  stay idempotent.
- Deleted immediately on success. Kept only for a failed, still-retryable attempt,
  and only for the retention window you choose (1, 6 or 24 hours).
- The bearer token is encrypted with an AES-GCM key held in the Android Keystore;
  only the ciphertext and nonce are stored. Backup and device-to-device transfer
  are disabled.

## Layout

| Path | What lives there |
| --- | --- |
| `core/` | Styles, languages, microphone preference, endpoint validation, insertion arithmetic, field eligibility |
| `gateway/` | HTTP client and the streaming WebSocket |
| `audio/` | `AudioRecord` capture, input routing, WAV writing, PCM conversion |
| `dictation/` | The pipeline, the microphone foreground service, retry |
| `accessibility/` | The accessibility service, insertion and undo |
| `overlay/` | The floating bubble |
| `ui/` | The Compose companion app |
| `settings/`, `data/`, `security/` | Preferences, history, the sealed token |

## Verified on hardware

The full path — bubble tap, microphone foreground service, capture, batch
delivery to a real whisper.cpp gateway over LAN HTTP, and direct insertion —
has been exercised on a physical Pixel 6a running Android 17, dictating into
Signal, WhatsApp, and Google search. Device testing surfaced three classes of
editor quirk now covered by unit tests:

- Fields that expose their placeholder as text (`isShowingHintText`, hint
  matching, and a cursor-placement probe for WhatsApp, which reports the
  placeholder with no hint and no flag).
- whisper.cpp emitting `[BLANK_AUDIO]` for silence, filtered by
  `TranscriptSanitizer` so markers never reach a field.
- The bubble's lifecycle, now tied to keyboard visibility through
  `BubblePolicy` (requires `flagRetrieveInteractiveWindows`).

## Not yet done

- Instrumented and Compose UI tests are configured but not written; the unit
  tests cover the pure logic and the gateway protocol against MockWebServer.
- The streaming path has only been exercised against MockWebServer; the test
  gateway's engine is batch-only. Verify against a Moonshine engine before
  relying on it.
- Samsung and other OEM battery-management work comes after the stock-Android
  path passes.
