# vocaphone for Android

A native Android voice keyboard for private speech-to-text on your phone, with
optional [VocaGateway](https://github.com/VocaHQ/vocagateway) for shared or
larger compute — the same product as the iPhone app. VocaPhone appears as a
normal Android input method: Gboard, Samsung Keyboard and other keyboards remain
available, while VocaPhone can be selected whenever you want to dictate into an
editable field. It inserts through Android's `InputConnection` and does not read
the field.

Android 13+ public beta APKs (and the full-flavor Play AAB) ship from GitHub
Releases on beta tags. Play Console setup is still outstanding, so the app is
not listed on Google Play yet. Maintainer steps: [docs/play-store.md](../docs/play-store.md).
The shipped build does not request accessibility-service or overlay access.

> Package name and application ID have been updated to `com.vocahq.vocaphone`;
> `assembleFullDebug` writes `vocaphone-fullDebug.apk`.

## Requirements

- Android 13 (API 33) or newer. Google Pixel is the baseline device.
- An on-device speech-to-text model, or a reachable VocaGateway if you choose that
  path.
- To build: JDK 21 exactly (the JDK bundled with current Android Studio works;
  other machines auto-provision it from `gradle/gradle-daemon-jvm.properties`).
  The version matters because F-Droid rebuilds the app on JDK 21 and
  reproducible builds need byte-identical javac output. You also need the
  Android SDK, CMake 3.22.1 and NDK 27.2.12479018. Everything else is pinned in
  `gradle/libs.versions.toml` and fetched by the Gradle wrapper.
- Clone with `git clone --recurse-submodules`; the pinned `whisper.cpp` source
  is required for the native local engine.

## Build

```sh
cd android
# macOS default SDK path; on Linux Android Studio usually uses $HOME/Android/Sdk
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
./gradlew assembleFullDebug
adb install -r app/build/outputs/apk/full/debug/vocaphone-fullDebug.apk
```

Verification the same way CI should run it:

```sh
./gradlew assembleFullDebug testFullDebugUnitTest lintFullDebug
```

`compileSdk` is 37 because current AndroidX releases require it. `targetSdk`
stays at 36, which is what Play requires from 31 August 2026.

## Build flavors

Every Gradle task name carries a flavor, because there are two:

| Flavor | Speech engines | Use it for |
| --- | --- | --- |
| `full` | whisper.cpp, plus sherpa-onnx via the prebuilt JNI libraries in `app/src/full/jniLibs` | Everyday development, GitHub beta releases, and the Play AAB |
| `fdroid` | whisper.cpp only, compiled from `third_party/whisper.cpp` | F-Droid only (never upload this flavour to Play) |

`full` is the default, so Android Studio selects it on import. The flavors differ
only in whether the prebuilt sherpa-onnx libraries are present; shared code asks
`LocalModelCatalog.sherpaAvailable` rather than assuming either way, and the
sherpa models are hidden from the picker when the library is absent.

## GitHub beta releases

Pushing a tag such as `v0.1.0-beta.14` (or the latest prerelease tag) runs
`.github/workflows/android-beta.yml`. Before tagging, bump `versionCode` and
`versionName` in `app/build.gradle.kts`; the workflow refuses to publish when
the tag and APK version do not match.

The repository needs these GitHub Actions secrets: `KEYSTORE_BASE64`,
`KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`, and
`PLAY_SERVICE_ACCOUNT_JSON` (Play Internal testing upload; the step is skipped
if it is empty). The workflow builds, tests, lints, verifies both APKs
(package, version, cert) and the full AAB signing cert via `keytool`
(package/version come from the matching full APK), and attaches these files
to the prerelease:

- `vocaphone.apk`
- `vocaphone.aab`: full-flavor Android App Bundle. CI uploads it to Play
  Internal testing when `PLAY_SERVICE_ACCOUNT_JSON` is set; see
  [docs/play-store.md](../docs/play-store.md). This tag workflow never uploads
  to production and never uploads the fdroid flavour.
- `vocaphone-fdroid.apk`: the `fdroid` flavour of the same tag. It exists so
  F-Droid can verify a from-source rebuild against it byte-for-byte and then
  publish this same signed APK (F-Droid "reproducible builds"). Install
  `vocaphone.apk` unless you specifically want the from-source-only variant.
- `SHA256SUMS.txt`
- `SIGNING-CERTIFICATE-SHA256.txt`

After downloading the release files, verify checksums with
`sha256sum -c SHA256SUMS.txt` on Linux or `shasum -a 256 -c SHA256SUMS.txt` on
macOS. Signing establishes a stable update identity and the checksum detects a
damaged or changed download; neither changes Android's Play Protect treatment
for apps installed outside an app store.

## First run

The companion app walks through setup and re-checks it on every resume, so a
permission revoked later or a keyboard selection changed in Android settings
shows up as an actionable repair prompt rather than a silent failure.

1. **Microphone** — recording only while you are dictating.
2. **Notifications** — the ongoing recording notification Android requires for a
   microphone foreground service.
3. **VocaPhone keyboard** — enable it in Android's keyboard settings, then select
   it from the keyboard picker.
4. **On-device model** — open **Speech** during setup or in Settings, download
   the recommended model with **Download and use**, or search the catalog. No
   gateway is required for this path.
5. **Optional gateway** — if you want shared or larger compute, **Scan QR code**
   against the gateway WebUI Overview pairing card, or paste the URL and bearer
   token, then **Test connection**, which reports reachability, token validity,
   the active engine, whether it is ready, and whether it supports streaming.

The catalog carries 32 whisper.cpp GGML builds from Tiny through Large v3,
including the q5 and q8 quantizations — a 574 MB Large v3 Turbo q5 is a far
better use of a phone than a full Small — and 12 sherpa-onnx models across seven
families (Moonshine, Parakeet TDT, SenseVoice, Dolphin, Canary, NeMo CTC and
Paraformer) covering English, Chinese, Japanese, Russian and European sets that
small whisper builds handle poorly. Only models this phone has the memory for are
offered, and sherpa-onnx models need an Arm ABI because its JNI library ships
prebuilt; whisper.cpp is compiled from source and runs on an x86_64 emulator too.

Every file of every model is pinned by exact byte length and SHA-256 at an
immutable upstream revision. A download is hashed as it streams, committed into
place only once each file matches, and then marked as digest-verified. Later
launches and dictations re-check sizes and that marker rather than rehashing
gigabytes; changing a pin in a new build invalidates the marker.

## VocaPhone keyboard

The microphone lives inside the keyboard and the transcript is written through
Android's `InputConnection`. VocaPhone refuses password and other sensitive
input types through its input policy.

Typing extras, all local to the phone:

- Optional number row and Compact / Default / Tall key height under Settings → Keyboard
- English word completions, next-word guesses, and spelling corrections (off in passwords)
- Swipe typing across letter keys, using the on-phone English word list.
  Suggestions and swipe are English only; there is no language pack to download.
- Clipboard chip (tap to paste, long press to dismiss) and optional clip history
- Emoji categories, recents, and optional ASCII emoticons
- Long-press letters for accents, long-press 1-0 for symbols, double-space for a period
- The globe key is gone; Android's keyboard switcher still changes IMEs

Suggestions may read about 32 characters around the cursor. The clipboard chip
and history stay on the phone. Dictation still never uses the clipboard, and
nothing from either path is logged.

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
- On-device mode (default): the model runs on the phone and audio never leaves
  the device.
- Gateway mode (only if you configured a gateway): streamed to `/v1/stream` as
  little-endian float32 frames when the active engine supports it; otherwise,
  and after a recoverable stream failure, the WAV goes through the batch
  endpoints. One session UUID is reused throughout, so retries stay idempotent.
- Deleted immediately on success. Kept only for a failed, still-retryable attempt,
  and only for the retention window you choose (1, 6 or 24 hours).
- When a gateway is configured, the bearer token is encrypted with an AES-GCM key
  held in the Android Keystore; only the ciphertext and nonce are stored. Backup
  and device-to-device transfer are disabled.

## Diagnostics

**Settings → About → Copy diagnostics** exports the app version, Android/device
context, setup state, a bounded event log, and the hardware numbers that matter
for on-device models: RAM, free storage, CPU/ABI, and how much space downloaded
models take. Events contain only timestamps, state transitions, error categories,
build version and whether the companion app or keyboard initiated them. They
never contain transcripts, typed text, audio, gateway hosts/URLs, tokens or
arbitrary package names. **Clear event log** removes the app-private log from the
device.

## Layout

| Path | What lives there |
| --- | --- |
| `core/` | Styles, languages, microphone preference, endpoint validation, insertion arithmetic, IME input policy |
| `gateway/` | HTTP client and the streaming WebSocket |
| `local/` | SHA-pinned model catalog, atomic downloads, native whisper.cpp loading and inference |
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
- The native CMake build and a real-device local-model transcription smoke test
  still need to run in an environment with a complete Android NDK/CMake install;
  CI is configured to install those toolchains, while local unit/lint checks
  cover the Kotlin paths.
- Samsung and other OEM keyboard behavior still needs a dedicated device pass.
