# Physical iPhone setup and acceptance

Simulator success does not verify custom-keyboard installation, microphone
handoff, background recording, App Group entitlements, or third-party text
insertion. Complete these steps on the actual iPhone.

## Signing prerequisites

1. Decide the final app bundle ID, keyboard bundle ID, and App Group.
2. Replace the placeholder IDs in `ios/project.yml`,
   `ios/LocalFlowShared/AppConfiguration.swift`, both entitlements files, and
   the URL type name in the app plist.
3. Run `xcodegen generate --spec ios/project.yml`.
4. Open `ios/LocalFlow.xcodeproj`, choose your Apple team for both targets, and
   enable the same App Group capability on each.
5. Connect the iPhone, select it as the run destination, and run LocalFlowApp.

The connected iPhone, automatic development signing, App Group provisioning,
and on-device installation have been exercised with the current checkout.

## On-device setup

1. Open Local Flow and grant microphone permission.
2. Leave “Keep Quick Dictation ready for 10 minutes” enabled. Confirm the app
   shows Quick Dictation as Ready and iOS displays its microphone indicator.
3. Enter the configured HTTP/HTTPS gateway URL and bearer token. This may be a
   trusted LAN URL such as `http://homelabone:8765/`, a Tailscale Serve URL, or
   an HTTPS VPS/reverse-proxy URL. Or open **Settings**, tap **Scan pairing QR
   code**, and scan the gateway WebUI Overview card. Approve camera and Local
   Network access when prompted.
4. Confirm that Save and test reports both gateway and model ready and shows the
   expected active model.
5. Choose Automatic microphone routing or iPhone Microphone, connect any AirPods
   or Bluetooth headset used in normal operation, and confirm **Input in use**.
6. Open Settings from Local Flow.
7. Under General → Keyboard → Keyboards, add Local Flow.
8. Enable Full Access. It is used for the app's shared state and private Mac
   workflow, not to collect unrelated typing.

## Required Phase 1 gate

Repeat this in Notes at least five times:

```text
Notes field → Local Flow keyboard → Start
→ containing app begins recording → manually swipe back
→ keyboard shows active recording → Finish
→ transcript becomes available → Insert
```

Then, while Quick Dictation still shows Ready, repeat:

```text
Notes field → Local Flow keyboard → Dictate
→ Notes remains visible → keyboard changes to Recording → Finish
→ transcript becomes available → Insert
```

Verify that:

- the microphone remains active while returning to Notes;
- later Dictate taps do not foreground Local Flow during the ready window;
- an expired or interrupted ready window falls back to opening Local Flow;
- Finish stops the recorder;
- the App Group state survives app switching;
- text is inserted directly, never via clipboard;
- one session never inserts twice;
- Cancel removes local audio;
- an offline Mac produces a recoverable error and Retry reuses the recording;
- Formal, Casual, Very Casual, and Excited produce the documented capitalization
  and punctuation behavior without changing dictated words;
- Automatic and iPhone Microphone preferences select the expected input;
- after recording stops, ordinary video/music audio returns to the speaker or
  connected output instead of remaining on the receiver.

Also test Messages, Mail, Safari, WhatsApp, Slack, and ChatGPT where installed.
Secure fields and apps that disable third-party keyboards are expected platform
limitations and must fail without presenting a gateway error.
