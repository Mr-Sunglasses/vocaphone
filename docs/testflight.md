# Shipping to TestFlight

How to take `ios/VocaPhone.xcodeproj` from a local build to a build installable
through TestFlight. This is the App Store Connect side; [device
setup](device-setup.md) covers the on-device acceptance pass that should
happen first, on real hardware, before you spend a TestFlight build on it.

## 1. Preflight checklist

Everything below was audited against the tree and is true as of this
checklist. Re-check any row you've touched since.

| Item | Status | Where |
| --- | --- | --- |
| Bundle IDs registered on team `92962VK378` | `com.vocahq.vocaphone`, `.keyboard`, `.liveactivity` | [decisions.md](decisions.md) |
| App Group registered on the same team | `group.com.vocahq` | same |
| App icon (1024×1024, light/dark/tinted, no alpha on the base image) | present | `ios/VocaPhoneApp/Assets.xcassets/AppIcon.appiconset` |
| Privacy manifests (App, Keyboard, Live Activity) | present | `PrivacyInfo.xcprivacy` in each target directory |
| Export compliance answered in the plist | `ITSAppUsesNonExemptEncryption = false` | `ios/VocaPhoneApp/Info.plist` — true because the app only uses HTTPS/Keychain, no custom or non-exempt cryptography |
| Marketing version / build number | `1.0` / `21` | `ios/project.yml` (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`) |
| App Group entitlement present on all three targets | app, keyboard, Live Activity all declare `group.com.vocahq` | `ios/VocaPhone*/*.entitlements` |

Before archiving, always run:

```console
cd ios && just gen
git status ios/VocaPhone.xcodeproj/project.pbxproj
```

`project.yml` is the source of truth; `just ci`'s first check exists precisely
because a stale, hand-edited `.pbxproj` is easy to produce (via Xcode's
automatic-signing UI silently rewriting `DEVELOPMENT_TEAM` or an entitlement)
and easy not to notice until an archive fails or ships broken. If `just gen`
produces a diff, that diff is either something to commit or a regression to
revert — decide which before archiving.

## 2. One-time App Store Connect setup

1. In [App Store Connect](https://appstoreconnect.apple.com), **My Apps → +**,
   create an app record for `com.vocahq.vocaphone` (the bundle ID must already
   exist in the Developer portal — it does, per the table above). Name: the
   marketing name you want on the App Store / TestFlight tab, not necessarily
   `CFBundleDisplayName`'s lowercase `vocaphone`.
2. **App Privacy** tab: answer the nutrition-label questionnaire from
   [privacy.md](privacy.md). The honest answers are unusually simple —
   - Data collected: **Audio Data**, linked to no identity, used only to
     provide app functionality (transcription), not used for tracking.
   - Data collected: **Product Interaction**, only when the user turns on
     usage reporting, not linked to identity, not used for tracking.
   - No third-party analytics service, no advertising, no data sharing.
   - No tracking (matches `NSPrivacyTracking = false` in the privacy
     manifests).
3. **Age rating**: answer the questionnaire; nothing in the app needs an
   18+ rating on content grounds, but consider the setup burden (the app is
   non-functional without a gateway the tester runs themselves) when writing
   TestFlight's "What to Test" notes — see §5.
4. Publish a **privacy policy URL**. [privacy.md](privacy.md) is thorough and
   ready to publish (GitHub Pages on this repo, or any static host); App Store
   Connect requires a live URL, not a repo-relative link.

## 3. Archive and upload

**Recommended path — Xcode Organizer**, because automatic signing recovers
from portal drift more gracefully here than from the command line:

1. `cd ios && just gen`
2. Open `VocaPhone.xcodeproj`, select the **VocaPhone** scheme and **Any iOS
   Device (arm64)** as the destination.
3. For each of the three targets (VocaPhoneApp, VocaPhoneKeyboard,
   VocaPhoneLiveActivity), open **Signing & Capabilities** and confirm: team
   is `92962VK378`, "Automatically manage signing" is on, and **App Groups**
   shows `group.com.vocahq` checked. If Xcode offers to "fix" a missing
   capability, let it — that's it registering state that already matches the
   entitlements files, not inventing new identity.
4. **Product → Archive**. This is the point where a provisioning-profile or
   entitlement mismatch across the three embedded targets first surfaces —
   budget time for at least one retry here, especially on the first archive
   after any bundle ID, App Group, or entitlements change.
5. In the Organizer window, **Distribute App → App Store Connect → Upload**,
   automatic signing for the distribution certificate too. Processing (Apple's
   server-side validation, including the privacy manifest and icon checks)
   typically takes a few minutes to under an hour.

**Command-line alternative**, for scripting or CI:

```console
cd ios && just gen
xcodebuild -project VocaPhone.xcodeproj -scheme VocaPhone \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/VocaPhone.xcarchive -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath build/VocaPhone.xcarchive \
  -exportPath build/export -exportOptionsPlist exportOptions.plist \
  -allowProvisioningUpdates
xcrun altool --upload-package build/export/VocaPhoneApp.ipa \
  --type ios --apple-id <app-apple-id> --bundle-id com.vocahq.vocaphone \
  --apiKey <key-id> --apiIssuer <issuer-id>
```

`exportOptions.plist` needs `method: app-store-connect` and
`teamID: 92962VK378`; `--apiKey`/`--apiIssuer` are an App Store Connect API
key (Users and Access → Integrations), not an Apple ID password.

A Mac with Xcode signed into team `92962VK378` can skip the API key.
Archive with automatic Release signing so App Groups stay on the binaries.
An unsigned archive plus export drops `group.com.vocahq`, and the keyboard
then fails with "Could not create a shared session."

```console
cd ios && just gen
xcodebuild -project VocaPhone.xcodeproj -scheme VocaPhone \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/VocaPhone.xcarchive \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=92962VK378 archive
xcodebuild -exportArchive -archivePath build/VocaPhone.xcarchive \
  -exportPath build/export -exportOptionsPlist exportOptions.plist \
  -allowProvisioningUpdates
```

## 4. GitHub tag uploads

iOS tags are prefixed: `ios/v1.0.21` means TestFlight **1.0 (21)**. Pushing
one runs `.github/workflows/ios-release.yml` only. Android is a different
prefix (`android/v0.1.1`). A joint drop is two tags on the same commit. See
[releasing.md](releasing.md).

Before tagging:

1. Bump `CURRENT_PROJECT_VERSION` in `ios/project.yml` (App Store Connect
   rejects a reused build number) and run `just ios gen`.
2. Leave `MARKETING_VERSION` at `1.0` until the App Store listing itself
   needs a new user-visible version.
3. Commit the regenerated `project.pbxproj`.
4. Tag `ios/v{MARKETING_VERSION}.{CURRENT_PROJECT_VERSION}` and push it.

Repository secrets (all three, or the macOS job never starts):

| Secret | What |
| --- | --- |
| `APP_STORE_CONNECT_API_KEY` | Body of the `.p8` (including `BEGIN PRIVATE KEY`) |
| `APP_STORE_CONNECT_API_KEY_ID` | Key ID from Users and Access → Integrations |
| `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID on that same page |

Create the key with the **Admin** role so Xcode can mint a
cloud-managed Apple Distribution certificate and App Store profiles. An
iOS-only drop without a tag is Actions → iOS TestFlight → Run workflow.

The workflow only uploads. It does not add the build to Internal or External
testing groups. A build can sit at Ready to Submit while testers stay on an
older Testing build.

## 5. TestFlight distribution

**Internal testing** (up to 100 App Store Connect users on the team) is the
right first track: it skips Beta App Review entirely, so a build is available
to testers as soon as processing finishes.

**External testing** (public link or up to 10,000 testers) requires Beta App
Review — a real reviewer installs and runs the build. This app cannot be
meaningfully reviewed without a reachable gateway: VocaPhone needs a
self-hosted transcription backend the reviewer doesn't have. Do not move to
an external group until either:

- a demo gateway is stood up specifically for review (rate-limited,
  review-only token), or
- the TestFlight build notes make unmistakably clear how a reviewer without a
  gateway should evaluate the app (what still works with no configured
  backend, and what doesn't).

For an internal build, fill in **Test Information → What to Test** with the
gateway prerequisite up front, e.g.: *"This app requires a self-hosted
transcription gateway; see [repository README] before installing. Without one
configured, Settings → Transcription → On this iPhone still works end to
end."* — assuming the on-device model path is functional without a gateway;
confirm that's still true before writing it.

## 6. After the first build lands

- Add testers under **TestFlight → Internal Testing** (App Store Connect
  Users and Access role, not a separate tester list, for internal groups).
- After processing finishes, add the new build to the Internal group (and
  External if the public link should follow). Ready to Submit means Apple
  accepted the binary, not that testers were moved.
- A build expires from TestFlight after 90 days. Groups only auto-notify
  testers of a new build once that build is in the group.
- Bump `CURRENT_PROJECT_VERSION` in `ios/project.yml` before every subsequent
  upload — App Store Connect rejects a re-upload of a build number it has
  already seen for this bundle ID, and `just gen` won't do this for you.
- Re-run the [device setup](device-setup.md) acceptance pass on a build
  actually pulled from TestFlight, not just a local archive — TestFlight's
  own install path (and a device that isn't the development iPhone) has
  exposed setup-step gaps in this project before.
