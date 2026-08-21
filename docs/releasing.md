# Releasing VocaPhone

How maintainers ship Android and iOS from this monorepo. Play Console and
App Store Connect listing work stay in [play-store.md](play-store.md) and
[testflight.md](testflight.md). This page is the tag and changelog contract.

Android and iOS are **independent products that share a git history**. They
do not share a version number, a store, or a changelog. A tag names exactly
one of them.

## Tag shapes

| Tag | Ships | GitHub Release | Store |
| --- | --- | --- | --- |
| `android/v0.1.1` | Android only | APK, AAB, fdroid APK, checksums. Marked **Latest**. | Play Internal testing |
| `android/v0.1.1-beta.1` | Android only | Same files. Marked **Pre-release**. | Play Internal testing |
| `ios/v1.0.21` | iOS only | Notes only (no IPA). Not Latest. | TestFlight |
| *two tags on the same commit* | Both | Two Releases, two changelogs | Both of the above |

Historical tags through `v0.1.0` / `v0.1.0-beta.20` are unprefixed Android
releases. They still exist on GitHub. New tags must use a prefix. Bare `v*`
no longer triggers either workflow.

Do **not** tag `v1.0.0` because the iOS marketing version is 1.0. That would
look like an Android 1.0.0 to anyone skimming Releases.

### What the numbers mean

**Android** — the tag *is* `versionName`. `android/v0.1.1` requires
`versionName = "0.1.1"` in `android/app/build.gradle.kts`. `versionCode` must
also go up. The workflow refuses to publish if the APK version and tag
disagree.

**iOS** — the tag encodes the pair App Store Connect shows as
`MARKETING_VERSION (CURRENT_PROJECT_VERSION)`:

```
ios/v{MARKETING_VERSION}.{CURRENT_PROJECT_VERSION}
ios/v1.0.21   →   TestFlight 1.0 (21)
```

`CURRENT_PROJECT_VERSION` must be unique for `com.vocahq.vocaphone`. Reusing
a build number App Store Connect has already seen is rejected even if the
marketing version changed. Leave `MARKETING_VERSION` at `1.0` until the App
Store listing itself needs a new user-visible version.

## Android only

```sh
# 1. Bump versionName and versionCode in android/app/build.gradle.kts
# 2. Commit on main
git tag android/v0.1.1          # or android/v0.1.1-beta.1
git push origin android/v0.1.1
```

`.github/workflows/android-release.yml` builds, publishes the GitHub Release,
and uploads the AAB to Play Internal when `PLAY_SERVICE_ACCOUNT_JSON` is set.
Closed testing, open testing, and production stay Console clicks.

## iOS only

```sh
# 1. Bump CURRENT_PROJECT_VERSION in ios/project.yml
# 2. just ios gen   # commit the regenerated project.pbxproj
# 3. Commit on main
git tag ios/v1.0.21
git push origin ios/v1.0.21
```

`.github/workflows/ios-release.yml` archives on `macos-15` and uploads to
App Store Connect / TestFlight when the three API key secrets are set. It
never submits for App Review and never assigns the build to a TestFlight
group. Check TestFlight first: if this `CURRENT_PROJECT_VERSION` is already
on App Store Connect, bump it before tagging or the upload is rejected.

Without a tag, **Actions → iOS TestFlight → Run workflow** uploads the
current ref the same way and does not create a GitHub Release.

An App Store IPA is not a sideloadable analog of `vocaphone.apk`. Testers
install from [TestFlight](https://testflight.apple.com/join/wd85wQ3W). The
iOS GitHub Release is notes plus a TestFlight link, not a binary.

## Both (joint product drop)

Tag the **same commit** twice. That is how other mobile monorepos keep
changelogs from mixing: two Releases, path-filtered notes, one SHA.

```sh
git tag android/v0.1.1
git tag ios/v1.0.21
git push origin android/v0.1.1 ios/v1.0.21
```

You get:

- GitHub Release **vocaphone Android v0.1.1** with APK/AAB
- GitHub Release **vocaphone iOS 1.0 (21)** with TestFlight notes
- Play Internal upload
- TestFlight upload

Generated notes for each tag start at the previous tag of **that prefix**, so
the Android notes are not stuffed with iOS-only PRs from last week (and vice
versa). The first prefixed Android tag still looks back at historical `v*`
tags so the changelog does not restart at zero.

If only one side is ready, ship that side. Do not wait.

## Why GitHub has one “Latest”

`/releases/latest` can point at only one Release. That slot is the Android
**stable** APK (`android/vX.Y.Z` with no hyphen). iOS Releases are created
with `--latest=false` so a TestFlight notes post never hijacks the APK
download. The public site pins a specific Android tag rather than
`/releases/latest` for the same reason; move the pin in `web/` when you cut
the next Android release people should install.

## Secrets

Android (existing): `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`,
`KEY_PASSWORD`, optional `PLAY_SERVICE_ACCOUNT_JSON`.

iOS TestFlight (all three, or the macOS job never starts):

| Secret | What |
| --- | --- |
| `APP_STORE_CONNECT_API_KEY` | Body of the `.p8` (including `BEGIN PRIVATE KEY`) |
| `APP_STORE_CONNECT_API_KEY_ID` | Key ID from Users and Access → Integrations |
| `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID on that same page |

Create the key with the **App Manager** role so Xcode can mint a
cloud-managed Apple Distribution certificate and App Store profiles.

`/build` on a pull request is unrelated: it makes an ad-hoc IPA for a
device UDID using a different set of secrets, and never talks to TestFlight.

## Checklist before a tag

**Android**

- [ ] `versionName` matches the tag after `android/v`
- [ ] `versionCode` is higher than the last Play upload
- [ ] No unsigned local experiment is in `android/`

**iOS**

- [ ] `CURRENT_PROJECT_VERSION` is higher than any build App Store Connect
      has already seen for `com.vocahq.vocaphone`
- [ ] `just ios gen` is committed (CI fails if `project.pbxproj` is stale)
- [ ] App Privacy nutrition label still matches [privacy.md](privacy.md)
      (Product Interaction if usage reporting is in the binary)
- [ ] After the upload, add the build to Internal (and External if the
      public link should follow). The workflow does not.

**Either**

- [ ] Tag from `main` (or from the commit you actually want testers to run)
- [ ] Do not reuse a tag; move it only by deleting and recreating, which
      rewrites history for anyone who already fetched it
