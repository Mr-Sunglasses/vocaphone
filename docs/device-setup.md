# Physical iPhone setup and acceptance

Simulator success does not verify custom-keyboard installation, microphone
handoff, background recording, App Group entitlements, or third-party text
insertion. Complete these steps on the actual iPhone.

New to the project? [The README's iPhone setup
section](../README.md#1-configure-and-install-the-iphone-app) covers getting
a build running at all — Simulator first, then a physical device — in
plainer language than this page. Come back here once you have a build on
your iPhone and want to run the full acceptance pass.

## Signing prerequisites

The bundle IDs, keyboard bundle ID, and App Group are already final — see
[decisions.md](decisions.md) — so there's nothing to rename before signing.

1. Open `ios/VocaPhone.xcodeproj` (`just ios gen` first if you haven't
   generated it yet) and choose your Apple team on all three targets — App,
   Keyboard, and Live Activity — in **Signing & Capabilities**.
2. Confirm the same App Group capability (`group.com.vocahq`) is enabled on
   all three. Automatic signing registers it under your team the first time,
   as long as your team has access to `com.vocahq.vocaphone` and friends —
   see [the README's iPhone setup
   section](../README.md#1-configure-and-install-the-iphone-app) if it
   doesn't.
3. Connect the iPhone, select it as the run destination, and run VocaPhoneApp.

The connected iPhone, automatic development signing, App Group provisioning,
and on-device installation have been exercised with the current checkout.

## On-device setup

1. Open vocaphone and grant microphone permission.
2. Leave “Keep Quick Dictation ready” enabled. Confirm the app shows Quick
   Dictation as Ready and iOS displays its microphone indicator. **Stay ready
   for** picks the window: 10 minutes (default), 20 minutes, or until vocaphone
   is closed.
3. Choose a transcription source. Either path completes the step on its own:
   - **On this iPhone** — under **Settings → Transcription**, pick **On this
     iPhone** and download a speech-to-text model. Wait for it to report
     *verified*: downloaded is not the same claim.
   - **Your gateway** — under **Settings → Transcription → Gateway**, enter the
     configured HTTP/HTTPS URL and bearer token. This may be a trusted LAN URL
     such as `http://homelabone:8765/`, a Tailscale Serve URL, or an HTTPS
     VPS/reverse-proxy URL. Or tap **Scan pairing QR code** and scan the gateway
     WebUI Overview card. Approve camera and Local Network access when prompted.
4. Confirm the Transcription screen reports the selected source as **Ready**, and
   that a gateway additionally names the loaded speech-to-text model.
5. Under **Settings → Dictation**, choose Automatic microphone routing or iPhone
   Microphone, connect any AirPods or Bluetooth headset used in normal
   operation, and confirm **Input in use**.
6. Under **Settings → Keyboard**, try each height — Compact, Standard, Tall — in
   a real host app and leave it on the one you want to accept.
7. Open iOS Settings from vocaphone.
8. Under General → Keyboard → Keyboards, add vocaphone.
9. Enable Full Access. It is used for the app's shared session state and for
   reaching the gateway you configured, not to collect unrelated typing.

## Required Phase 1 gate

Repeat this in Notes at least five times:

```text
Notes field → vocaphone keyboard → Start
→ containing app begins recording → manually swipe back
→ keyboard shows active recording → Finish
→ transcript becomes available → Insert
```

Then, while Quick Dictation still shows Ready, repeat:

```text
Notes field → vocaphone keyboard → Dictate
→ Notes remains visible → keyboard changes to Recording → Finish
→ transcript becomes available → Insert
```

Verify that:

- the microphone remains active while returning to Notes;
- later Dictate taps do not foreground vocaphone during the ready window;
- an expired or interrupted ready window falls back to opening vocaphone;
- Finish stops the recorder;
- the App Group state survives app switching;
- text is inserted directly, never via clipboard;
- one session never inserts twice;
- Cancel removes local audio;
- an unreachable gateway produces a recoverable error and Retry reuses the
  recording;
- the keyboard, the app and the Live Activity name the same processing location
  for the same session — "Transcribing on this iPhone" or "Transcribing on your
  gateway", never a guess;
- Formal, Casual, Very Casual, and Excited produce the documented capitalization
  and punctuation behavior without changing dictated words;
- Automatic and iPhone Microphone preferences select the expected input;
- after recording stops, ordinary video/music audio returns to the speaker or
  connected output instead of remaining on the receiver.

Also test Messages, Mail, Safari, WhatsApp, Slack, and ChatGPT where installed.
Secure fields and apps that disable third-party keyboards are expected platform
limitations and must fail without presenting a gateway error.

## Typing gate

Simulator runs prove none of the memory, jetsam, haptic or Full Access
behaviour here. Run these on at least two devices, including the oldest
supported one.

- Compose, complete, correct, revert, assert, learn and predict in Notes,
  Messages, Safari's address bar and one third-party app. No missed keystrokes
  at speed, and no visible lag on the suggestion row.
- Type an obvious typo and press space: it corrects. Press Delete immediately:
  the typed word comes back exactly, with its spacing, and typing it again does
  not correct it a second time.
- Tap the quoted word on the left of the row: what you typed stays, and the
  keyboard stops correcting it.
- Password, new-password, one-time-code and PIN fields: **no suggestion row at
  all**, and nothing learned from them. Check a card-number field too.
- Turn Full Access off. Suggestions, correction and prediction still work;
  learned words stop persisting and the Keyboard settings screen says so;
  keyboard haptics stop working, which is also stated there.
- Type continuously for two minutes in a long document. The keyboard must not
  flicker, reset, or lose the composition — that is what a jetsam looks like.
- Long-press `$`, `-`, `?` for symbol alternates, and `.` in a URL field for
  `.com`. Hold the `123` key to open the emoji panel; the keyboard's height must
  not change when it does.
- Swipe a few words with **Settings → Keyboard → Swipe to type** on. Decide
  whether the recogniser has earned being on by default; if not, it ships off.
- VoiceOver: the chips are reachable and activate, candidate changes are *not*
  announced over every keystroke, and the accent alternates and the emoji panel
  are reachable through the plane key's custom actions.
- Confirm the whole dictation matrix below still passes. Typing intelligence
  must not have touched hand-off, Quick Dictation, insertion or undo.

## Quick Dictation reliability gate

Run these checks on a physical iPhone after changing audio or App Group code:

- Start and finish from the keyboard several times. Recording and transcript
  states should update immediately; the slower polling path is only a fallback.
- Expand the standby Dynamic Island and tap **Pause Quick Dictation**. The
  Live Activity and orange microphone indicator must disappear without opening
  vocaphone, and the next keyboard dictation must open the app. Then reopen
  vocaphone: standby must arm again on its own, and the Settings toggle must
  still read as on — a pause is not a preference change.
- Set **Stay ready for** to *Until I close vocaphone*, background the app, and
  confirm standby is still Ready well past 10 minutes. Force-quit vocaphone and
  confirm the keyboard falls back to opening the app.
- Upgrading with Quick Dictation already off must show the one-time card on
  Home offering to turn it back on, and must not arm the microphone until that
  card is answered. **Not now** has to keep it off and never ask again.
- Force-quit vocaphone while Quick Dictation is ready, wait at least 7 seconds,
  and tap Dictate. The keyboard must treat the heartbeat as stale and open the
  app instead of claiming that standby is ready.
- During standby and during an active recording, test a phone call or Siri, an
  AirPods disconnect, and reconnecting an input. Readiness and the Live Activity
  must clear whenever input is unavailable. An interrupted recording should
  finish and preserve the audio captured before the interruption.
- Hold the spacebar until **Cursor control** is announced, then drag left and
  right. The insertion point should move without inserting a space. A normal
  spacebar tap must still insert exactly one space.
- With recording sounds disabled, confirm there are no cues. Enable them in
  vocaphone Settings and confirm the short start/stop cues play but are absent
  from the resulting transcript.
- Disable Full Access and reopen the keyboard. The locked bar must appear with
  the exact manual path (Settings → General → Keyboard → Keyboards → vocaphone →
  Allow Full Access) and a disabled action; re-enable Full Access before
  continuing.
- Long-press `a`, `e`, `o`, `s` and `n` in a real host app. The accent popover
  must open above the key, follow a sliding finger, commit on lift, and cancel
  cleanly on a plane switch or when the keyboard is dismissed. With Shift or
  Caps Lock engaged the alternatives must be uppercase. With VoiceOver running
  the gesture must not fire at all — the accents appear as the key's custom
  actions instead.
- Switch between Compact, Standard and Tall. In each, check that the spacebar
  looks centred, that keys near the gutters and the screen edges still register,
  and that Tall does not cover an unreasonable amount of the host app.
- Watch the Live Activity through one whole dictation. The red recording
  treatment must end when capture ends, not when the transcript arrives, and
  Quick Dictation standby must never look like an active recording.
- Export diagnostics from vocaphone Settings. Confirm the file contains only
  timestamps, build information, process source, finite state/lifecycle events,
  and errors—never dictated or typed text, audio, gateway addresses, tokens, or
  microphone names. Clear diagnostics and confirm a new export has no old rows.
