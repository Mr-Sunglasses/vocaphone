# vocaphone for Android

A native Android voice keyboard for the same self-hosted vocaphone gateway the
iPhone app uses. VocaPhone appears as a normal Android input method: Gboard,
Samsung Keyboard and other keyboards remain available, while VocaPhone can be
selected whenever you want to dictate into an editable field. It inserts through
Android's `InputConnection` and does not read the field.

Distributed as a private APK. Google Play publication is deferred. The shipped
APK does not request accessibility-service or overlay access.

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

## GitHub beta releases

Pushing a tag such as `v0.1.0-beta.7` runs
`.github/workflows/android-beta.yml`. Before tagging, bump `versionCode` and
`versionName` in `app/build.gradle.kts`; the workflow refuses to publish when
the tag and APK version do not match.

The repository needs these GitHub Actions secrets: `KEYSTORE_BASE64`,
`KEYSTORE_PASSWORD`, `KEY_ALIAS`, and `KEY_PASSWORD`. The workflow builds,
tests, lints, verifies the release signature against the pinned public
certificate fingerprint, and attaches these files to the prerelease:

- `vocaphone.apk`
- `SHA256SUMS.txt`
- `SIGNING-CERTIFICATE-SHA256.txt`

After downloading all three files, verify the APK checksum with
`sha256sum -c SHA256SUMS.txt` on Linux or
`shasum -a 256 -c SHA256SUMS.txt` on macOS. Signing establishes a stable update
identity and the checksum detects a damaged or changed download; neither
changes Android's Play Protect treatment for apps installed outside an app store.

## First run

The companion app walks through setup and re-checks it on every resume, so a
permission revoked later or a keyboard selection changed in Android settings
shows up as an actionable repair prompt rather than a silent failure.

1. **Microphone** — recording only while you are dictating.
2. **Notifications** — the ongoing recording notification Android requires for a
   microphone foreground service.
3. **VocaPhone keyboard** — enable it in Android's keyboard settings, then select
   it from the keyboard picker.
4. **Gateway address and token** — either **Scan QR code** against the gateway
   WebUI Overview pairing card, or paste the URL and bearer token, then
   **Test connection**, which reports reachability, token validity, the active
   engine, whether it is ready, and whether it supports streaming.

## VocaPhone keyboard

The microphone lives inside the keyboard and the transcript is written through
Android's `InputConnection`. The keyboard only receives the editor connection
provided by Android; it does not scrape or store surrounding field contents.
VocaPhone refuses password and other sensitive input types through its input
policy.

## Dictating

- Open an editable field and select **VocaPhone keyboard** from the keyboard
  picker.
- Tap **Dictate**, speak, then tap **Finish**. The keyboard shows recording state,
  elapsed time, input level and a streaming partial transcript when available.
- Recording warns a minute before the five-minute cap and stops there.
- Password and other sensitive input types disable dictation rather than exposing
  their contents to the keyboard.

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

## Diagnostics

**Settings → About → Copy diagnostics** exports the app version, Android/device
context, setup state and a bounded event log. Events contain only timestamps,
state transitions, error categories, build version and whether the companion app
or keyboard initiated them. They never contain transcripts, typed text, audio,
gateway hosts/URLs, tokens or arbitrary package names. **Clear event log** removes
the app-private log from the device.

## Layout

| Path | What lives there |
| --- | --- |
| `core/` | Styles, languages, microphone preference, endpoint validation, insertion arithmetic, IME input policy |
| `gateway/` | HTTP client and the streaming WebSocket |
| `audio/` | `AudioRecord` capture, input routing, WAV writing, PCM conversion |
| `dictation/` | The pipeline, the microphone foreground service, retry |
| `ime/` | The system keyboard and `InputConnection` insertion |
| `ui/` | The Compose companion app |
| `settings/`, `data/`, `security/` | Preferences, history, the sealed token |

## Verified on hardware

The IME install, enablement, selection and rendered keyboard have been exercised
on a physical POCO F1 running Android 14. The signed release was installed and
the device was restored to its previous keyboard afterwards. Unit tests cover
the input policy, cursor insertion arithmetic, transcript sanitization, privacy
log bounds and the gateway protocol.

## Not yet done

- Instrumented and Compose UI tests are configured but not written; the unit
  tests cover the pure logic and the gateway protocol against MockWebServer.
- The streaming path has only been exercised against MockWebServer; the test
  gateway's engine is batch-only. Verify against a Moonshine engine before
  relying on it.
- Samsung and other OEM keyboard behavior still needs a dedicated device pass.
