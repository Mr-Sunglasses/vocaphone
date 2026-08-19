# Preparing Google Play (maintainers)

How to take a VocaPhone Android beta tag from GitHub Releases into Play Console.
This is Console and listing work. The app is not listed on Play until that work
is finished; there is no store URL to publish yet.

Beta tags attach a signed full-flavor AAB as `vocaphone.aab`. When
`PLAY_SERVICE_ACCOUNT_JSON` is set, the beta tag workflow uploads that AAB to
Internal testing after the GitHub Release is published. The step is skipped if
the secret is empty, so testers still get the GitHub APKs if Play is unset or
fails. This tag workflow never uploads to production.

The Play Developer API account is
`vocaphone-play-upload@level-approach-506001-h1.iam.gserviceaccount.com`.
It can view this app and release it to testing tracks only.

## What to upload

| Artifact | Flavor | Use |
| --- | --- | --- |
| `vocaphone.aab` | `full` | Play Internal testing (CI when the secret is set) |
| `vocaphone.apk` | `full` | Sideload / GitHub beta |
| `vocaphone-fdroid.apk` | `fdroid` | F-Droid rebuild verification only |

Upload the full AAB only. Never upload the fdroid APK or an fdroid bundle to
Play. The fdroid flavour drops prebuilt sherpa-onnx / ONNX Runtime so F-Droid
can rebuild from source; Play testers should get the full catalog.

Package: `com.vocahq.vocaphone`. Current tree on main: `versionCode` 18,
`versionName` `0.1.0-beta.18`. Keep that until the next Play-bound tag needs a
bump; the beta workflow refuses to publish when the tag and APK version disagree.

`dependenciesInfo.includeInApk` / `includeInBundle` stay `false` so AGP does
not embed Play dependency metadata. Do not turn those back on.

## Signing

The GitHub release keystore already signs `vocaphone.apk`, `vocaphone-fdroid.apk`,
and `vocaphone.aab`. The public certificate SHA-256 is published with every
beta release in `SIGNING-CERTIFICATE-SHA256.txt` (pinned in
`.github/workflows/android-beta.yml`).

In Play Console, use Play App Signing:

1. Create the app with package `com.vocahq.vocaphone`.
2. When asked for the upload key, register the existing release keystore (the
   one behind `KEYSTORE_BASE64` / local `android/keystore.properties`).
3. Let Google hold the app signing key. Keep the upload keystore for CI and for
   future AAB uploads.

Do not generate a second upload key unless the first is lost or rotated on
purpose.

## Track order

The beta tag workflow uses the Play API track name `internal`. If that name is
missing, `qa` is the only other name to try. Wider testing and production stay
in Console. This tag workflow never uploads to production.

## Permissions (Console justification notes)

The app does not use accessibility services or overlay / draw-over-other-apps.

| Permission | Why |
| --- | --- |
| `RECORD_AUDIO` | Dictation while the user holds Dictate |
| `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_MICROPHONE` | Ongoing recording notification Android requires for mic capture |
| `CAMERA` | Optional gateway pairing via "Scan QR" only |
| `INTERNET` | Optional gateway traffic and on-device model downloads |
| `POST_NOTIFICATIONS` | The recording notification on Android 13+ |
| `MODIFY_AUDIO_SETTINGS` | Microphone routing (Bluetooth headset call mode, etc.) |

## Data safety

- No analytics SDK and no third-party speech cloud.
- Default path is on-device transcription; audio stays on the phone.
- Audio leaves the device only if the user configures a gateway they control.
- No accounts or subscription.

Use [privacy.md](privacy.md) and the Android README "What happens to your audio"
section when filling the Data safety form. Play still requires a hosted
privacy policy URL (a live page, not a repo-relative path).

## Listing assets

Fastlane stays metadata only. It does not upload binaries. Copy lives under
`fastlane/metadata/android/en-US/`:

- `title.txt`, `short_description.txt`, `full_description.txt`
- `images/icon.png` (512×512)
- `images/featureGraphic.png` (1024×500 brand field + mark)
- `images/phoneScreenshots/` (five phone screenshots)
- `changelogs/<versionCode>.txt` (e.g. `changelogs/14.txt` for beta.14)

Regenerate the feature graphic from brand assets when the mark changes:

```sh
python3 - <<'PY'
from PIL import Image
W, H, S = 1024, 500, 280
canvas = Image.new("RGB", (W, H), (0x0F, 0x6B, 0x57))
logo = Image.open("assets/vocaphone-logo-512.png").convert("RGBA").resize((S, S))
canvas.paste(logo, ((W - S) // 2, (H - S) // 2), logo)
canvas.save("fastlane/metadata/android/en-US/images/featureGraphic.png")
PY
```

## Console checklist (still on you)

1. Play developer account and app record for `com.vocahq.vocaphone`
2. Play App Signing with the existing upload keystore
3. Hosted privacy policy URL
4. Data safety form (no analytics; on-device default; gateway optional)
5. Content rating questionnaire
6. Closed testing track before production
7. Confirm Internal testing received `vocaphone.aab` from the beta tag workflow
   (upload by hand from the matching GitHub Release if the secret was unset)
8. Confirm listing copy and graphics in Fastlane match what you paste into Console

## Building the AAB locally

Same secrets as a beta APK. From `android/`:

```sh
export KEYSTORE_FILE=… KEYSTORE_PASSWORD=… KEY_ALIAS=… KEY_PASSWORD=…
./gradlew bundleFullRelease
```

Output under `app/build/outputs/bundle/fullRelease/`. Prefer the CI artifact
from a beta tag so the signing certificate matches the published fingerprint.

## Related docs

- [Android client](../android/README.md): build flavors, beta tags, keyboard setup
- [TestFlight](testflight.md): iOS counterpart
- [Privacy](privacy.md): data flow and threat model
