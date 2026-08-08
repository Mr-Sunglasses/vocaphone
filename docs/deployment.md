# Gateway deployment

The headless gateway is maintained in
[VocaHQ/vocagateway](https://github.com/VocaHQ/vocagateway) and is checked out here
as the `server/` git submodule.

Canonical guides (after `git submodule update --init --recursive`):

| Topic | Location |
| --- | --- |
| Full deployment reference | [server/docs/deployment.md](../server/docs/deployment.md) |
| Gateway README (quick start, engines, config) | [server/README.md](../server/README.md) |
| Private Tailscale Serve | [server/docs/tailscale.md](../server/docs/tailscale.md) |
| Gateway troubleshooting | [server/docs/troubleshooting.md](../server/docs/troubleshooting.md) |

Phone-specific setup (signing, keyboard, bubble) stays in this repository:

- [Device setup](device-setup.md)
- [Android client](../android/README.md)
- [Troubleshooting (keyboard / mic / insertion)](troubleshooting.md)

## Migrating from the Local Flow working name (v0.3.0)

Gateway token, config, and volume renames are documented in
[server/docs/deployment.md](../server/docs/deployment.md#migrating-from-the-local-flow-working-name-v030).

### iOS / Android installations

Due to changed bundle identifiers (`com.vocahq.vocaphone*`), App Group
(`group.com.vocahq.vocaphone`), and application ID (`com.vocahq.vocaphone`),
existing iOS and Android installations are not upgraded in place:

- **iOS**: Delete the old app from the device. Rebuild the renamed Xcode project
  (`ios/VocaPhone.xcodeproj`) with the new bundle IDs, re-register the App Group
  capability, install, and pair again.
- **iOS Apple Developer registration**: Register the new bundle identifiers and
  App Group under your existing team in the Apple Developer portal. See
  [decisions.md](decisions.md) for the final identifiers.
- **Android**: Uninstall the old APK (`io.github.mrsunglasses.localflow`) before
  installing the new one. `adb install -r` will **not** replace it — the
  application ID changed to `com.vocahq.vocaphone`, so a side-by-side install
  leaves both apps on the device. The Android Keystore token ciphertext is not
  portable between application IDs — re-enter the token and re-pair.
