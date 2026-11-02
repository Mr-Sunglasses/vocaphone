# Privacy and threat model

## Data flow

The containing iPhone app records only after an explicit Start action. It keeps
recoverable audio in the App Group container, sends it to the configured
bearer-authenticated gateway over HTTP or HTTPS, and deletes the iPhone copy
after a transcript is safely stored. HTTPS or an encrypted private network is
recommended so the recording and token are protected in transit.

For iPhone completed-file uploads and retries, the app prepares a temporary
mono 16 kHz AAC/M4A copy at 48 kbps to reduce transfer size. The recoverable WAV
stays on the phone until success. The temporary copy is removed when the upload ends,
including on failure or cancellation; if encoding fails or the copy would be
larger, the app sends the WAV. On-device transcription uses the WAV.

A recording in which the model finds no speech is deleted as soon as that is
known, the same as after a transcript: the session ends there, and there is
nothing a retry could recover.

For gateway models that do not decode incrementally (including Whisper), the
iPhone sends mono 16 kHz, 16-bit PCM through a bounded HTTP/HTTPS upload while
the dictation is being recorded. The gateway receives it as a streaming WAV
and transcribes only after Finish closes the upload. A supporting gateway
returns the transcript in the upload response; an older gateway receives a
separate Finish request with the same session ID, without another audio upload.
Session setup overlaps
recording. Failed connections, stalled transfers, or dropped chunks abandon
this upload and use the complete local WAV for the compressed batch fallback.
Only audio from the explicit dictation is sent, never Quick Dictation standby
buffers. The existing gateway authentication, limits, and retention still apply.

When Quick Dictation is enabled, the containing app may keep microphone input
active so later keyboard actions do not need another app handoff. The window is
the user's choice — 10 minutes by default, 20 minutes, or until vocaphone is
closed. The system's orange microphone indicator remains visible. Audio buffers
captured while waiting are discarded in memory: they are not written to disk,
placed in shared state, or uploaded. Only audio after an explicit Dictate action
is saved for transcription. The user can turn Quick Dictation off in the app,
or pause the current window from the Live Activity without changing the
setting.

With on-device transcription, the dictation's own audio is also passed, in
memory, to a voice activity detector bundled in the app (Silero VAD) and to the
selected model while the user is still speaking, so the transcript is ready
sooner. That audio is the same dictation audio already being recorded; it goes
nowhere else, is not kept after the dictation, and nothing it produces beyond
the transcript is stored. Diagnostics record only a duration, a yes/no for
whether the text was decoded before Finish, and how many milliseconds of
trailing silence were left out.

**Fix grammar (English)** is off by default (Settings › Dictation › Output). It
is only offered where the app already ships ONNX Runtime: the iOS app and the
Android `full` and `x` builds, not the F-Droid build. Turning it on first
downloads a 28 MB grammar model, MindType tagger v2.0 by Mindscend
(Apache-2.0), from the `onnx/` folder of
[`Mindscend/mindtype-tagger-v2.0`](https://huggingface.co/Mindscend/mindtype-tagger-v2.0)
at revision `e58cbb68c382a894a9f6de704fe385ec260f0949`.
Every file is checked against a pinned size and SHA-256 before it is used,
the same way as a speech model; the model itself is
`onnx/mindtype_tagger.onnx`, SHA-256
`cde26b40d62216c0b5680725b5e3f3b438f50cb6d02e05c395bf13059467da76`. An update
from a build that used v1.5 deletes the old model and, if the user had
downloaded it, downloads v2.0 in its place; a download that fails is tried
again at each app start while the model is missing for someone who agreed to
it. That agreement is stored separately from the switches
(`grammar_model_requested` on Android, `grammarModelRequested` in the App
Group defaults on iOS): it is recorded when the user starts a download from
Fix grammar or from Writing check's offer, withdrawn (with Fix grammar) if
they cancel one, and carried over from older builds only for those who had a
grammar model on the phone or Fix grammar on. "Check while typing" on its own
never downloads the model. The download sends nothing but the request for
those files. Once it is on, the
finished on-device English transcript is corrected on the phone, in memory,
before it is styled; the text is never sent anywhere for this, and nothing
the model produces is stored beyond the transcript itself. It never runs on a
gateway transcript, on another language, or on the Raw style, and it never
runs in the iOS keyboard extension. If the model cannot run, the transcript is
used unchanged and the diagnostic log records only that it happened
(`grammar_failed` and similar), never any text. It reports nothing to usage
statistics.

**Writing check (English)** is VocaPhone's Grammarly-style checker for typed
text. It has four ways in, and every one of them checks on the phone:

- **The Writing check button** at the start of the keyboard's suggestion row,
  which checks the field's text when tapped.
- **Check while typing** in the keyboard (off by default; Android: Settings ›
  Keyboard › Writing check; iOS: Keyboard › Writing check), which checks after
  each pause in typing and shows the count on the same button.
- **The Writing check screen** in the app, which opens on text the user pastes
  or writes, on a History transcript, or on the field's text when the
  keyboard's "Open app" is tapped.
- **Android's text selection menu and Share sheet** ("Writing check"): the
  selected or shared text is handed to the app by the system, and when the
  field is editable "Replace" hands the corrected text back to that app.
- **Android's system spell checker**, only if the user picks VocaPhone under
  the system's spell checker setting.

There are four checkers. The **rules** (`assets/keyboard/writing-rules.json`),
the **spelling dictionary** (`assets/keyboard/en-spelling.txt`, a SCOWL word
list) and the **agreement checks** with their part-of-speech tagger
(`assets/keyboard/en-pos.bin`) ship inside the app and the keyboard and need no
download, no ONNX Runtime and no network, so they also run in the F-Droid build
and inside the iOS keyboard extension. The **grammar model** is the Fix grammar model above,
used only once it has been downloaded. None of them sends the text anywhere. Suggestions are
only *offered*: nothing in a field changes unless the user taps one, with one
exception the user has to turn on, **Fix obvious typos as I type**, which
corrects known misspellings and missing apostrophes after a pause and offers
Undo. It never runs in password, address, link, e-mail, name or search fields,
in fields that turned suggestions or autocorrection off, with suggestions off,
or on text that does not read as English, and not while text is selected.
Tapping the Writing check button is the user asking, so on iOS it also checks a
field that turned autocorrection off, as many chat apps do; it still never
reads password, one-time code, number, link, e-mail or address fields. The
user's own words (dictionary, custom vocabulary, learned words, snippet
triggers, and on iOS their text replacements and contact names) are never
flagged or changed.

- **Android keyboard:** the keyboard runs in the app's own process. After a
  pause it reads the field around the cursor once
  (`getSurroundingText`, at most 2,000 characters on each side), checks it in
  memory, and keeps the model's answer for each sentence only for as long as
  the user stays in that field. The model is released a minute after the
  keyboard closes.
- **Android spell checker:** the system binds to it (`BIND_TEXT_SERVICE`) and
  hands it the text of the field being edited, a sentence at a time, as it
  does for any spell checker; it is checked in the app's process and only
  correctness is reported back to the field. It replaces the phone's own
  spell checker for as long as it is chosen.
- **iOS keyboard:** the rules run in the extension. A keyboard extension is not
  given enough memory to run the model, so sentences the model has not seen
  are handed to the vocaphone app on the same iPhone: the keyboard writes them
  to one file in the App Group (`typed-grammar-request.json`, at most twelve
  sentences), which the app deletes as it reads it, and the app writes the
  model's text back to `typed-grammar-answer.json`, which the keyboard deletes
  as it reads it. The request carries only those of the user's protected
  words that occur in the sentences, never the whole list, so the address
  book is not copied into it. A question nobody collects is deleted when the
  keyboard closes, when checking stops, or when the app next starts; an answer
  nobody collects is deleted by the app five seconds after it is written. This
  needs Full Access (it is the App Group) and only works while the app is
  running, which Quick Dictation keeps it doing in the background; otherwise
  only the rules run and nothing is written. "Whole message" reads past the
  window iOS gives a keyboard by moving the cursor to each end of the field
  and back, only when tapped, and stops if the user taps or types in the
  field meanwhile. "Open app" writes the field's text to
  `writing-draft.json` in the App Group, which the app deletes as it opens it.
  The keyboard deletes it if the app does not open, and the app and keyboard
  delete one left a minute or more on their next start. The keyboard extension still never loads the
  model, makes no network call, and reports nothing.

Neither platform logs, stores beyond those transient files, or reports any of
the text. Failures are recorded only as the content-free grammar events above.

**History** keeps, beside a transcript Fix grammar changed, the same
transcript without the grammar stage, so the change can be seen and undone. It
lives and is deleted with the transcript.

With **Show words while speaking** turned on (Settings › Dictation; off by
default), while the recording is still going, the words those early decodes
produced are written to a small file beside the session record in the App Group, so the
keyboard can show them under the waveform. It is the same place, and the same
kind of text, as the finished transcript: nothing new leaves the phone. The file
is deleted as soon as the session leaves the recording state, and with the
session itself. It is never logged, and it is never what gets inserted — the
finished transcript is.

### Android gateway audio

An explicit Android dictation writes a recoverable mono 16 kHz WAV in private
app storage. On a gateway route, a bounded background consumer also sends that
dictation's PCM16 audio to the configured bearer-authenticated HTTP/HTTPS
endpoint during recording. Batch models receive a streaming WAV; they
transcribe after Finish closes the upload. A supporting gateway returns that
transcript in the upload response; an older gateway receives a separate Finish
request using the same session ID, without a second audio upload. Models with incremental support
retain their authenticated WebSocket path. On-device dictation sends no audio
to the gateway, even when gateway settings remain configured.

If this live transport fails or drops frames, the complete WAV remains the
fallback. Completed-file uploads and retries prepare a temporary mono 16 kHz
AAC/M4A at 48 kbps in private app cache and send it only when it is smaller.
An encoding failure or unfamiliar format sends the original file. Temporary
copies are removed after success, failure, and cancellation; the recoverable
WAV follows the existing success/retry lifecycle. Audio conversion happens
off the microphone and UI threads. Existing gateway authentication, upload
limits, and retention apply to both paths.

### Android recordings kept for Retry

The Android recording is deleted as soon as a transcript is produced, whether
or not it is inserted. A failed dictation keeps its WAV in private app storage
only when Retry can still help:

- a gateway that could not be reached, was busy, or failed in a way that may
  not repeat, and an on-device transcription that failed;
- a gateway that rejected the bearer token (HTTP 401/403) or whose model does
  not support the chosen language. Sending the same request again would fail
  the same way, but after the token or language is changed in Settings the
  same recording can succeed, so it is kept rather than making the user say
  it again. A Retry of a language rejection uses the language selected now.

Every other failure deletes the recording immediately: a recording larger than
the gateway accepts (HTTP 413), one the gateway could not read, an empty
transcript, an interrupted or silent microphone. A kept recording is deleted
when a Retry succeeds, when its History entry is deleted, or when the audio
retention window chosen under Settings › Privacy passes (1, 6 or 24 hours; 6 by
default), whichever comes first.

Leaving a text field, or switching keyboards, while the keyboard is dictating
no longer discards the recording. Recording stops at that moment and the
dictation is transcribed as usual; the transcript is saved to History without
being inserted, because whichever field has focus by then is not the one it was
meant for. The keyboard offers it as "Saved to History" with an Insert button
for a few seconds; inserting it is always the user's tap. Its recording follows
the rules above.

The gateway host stores randomized audio names under its private data directory.
On success, original and normalized audio are deleted by default. Failed and
abandoned sessions remain for the retry window (24 hours by default), after
which `vocaphone-cleanup` removes them. SQLite stores lifecycle metadata and the
result needed for idempotent retry.

## Security controls

- Configurable gateway binding, with loopback recommended for private deployments
- Tailscale Serve private ingress over a loopback listener; no Funnel
- Independent high-entropy bearer token, with additional named per-device
  tokens available so losing one phone means revoking that device's token
  rather than rotating every paired device's credential (see "Per-device
  tokens" below)
- Token stored in an iPhone Keychain item and a mode-600 Mac file
- Strict upload types, byte limits, duration limits, and one transcription slot
- FFmpeg and `whisper.cpp` invoked with argument arrays, never a shell
- Opaque file references and canonical server-owned paths
- No third-party analytics or transcription service; see "Usage reporting" below
  for the optional, off-by-default counters the apps can send to a server
  VocaHQ self-hosts
- No ordinary logging of audio, transcripts, tokens, or private endpoint values
- In-memory operational metrics contain only counts, queue activity, stage
  timings, real-time factor, peak process memory, and process uptime; they reset
  on restart and include no transcript or session data
- Docker Compose mounts the bearer token as a secret instead of a container
  environment variable; `/data` is the only persistent application volume

The Compose source token is normally stored in the host-only `gateway/.env` file
before Docker mounts it at `/run/secrets/vocagateway_token`. Keep that file at mode
`600`, exclude it from backups shared with other people, and never commit it.

Streaming (Moonshine's streaming tiers, or sherpa-onnx's streaming Zipformer
model) uses the same bearer token and configured HTTP/HTTPS host as the batch
API (`ws://` on trusted HTTP networks, `wss://` with HTTPS). The iPhone
continues writing the bounded WAV while streaming so a socket interruption can
fall back without losing the dictation. Partial transcripts are not persisted by
the gateway or written to ordinary logs.

On Apple silicon, the managed WhisperKit service binds to a random
`127.0.0.1` port and is never published to the LAN or tailnet. Only the
authenticated vocaphone gateway is externally reachable; the sidecar receives
the already-local normalized WAV and does not add a cloud hop.

## Network transport choices

Tailscale is recommended but not required. The iPhone app accepts both HTTP and
HTTPS gateway URLs so it can reach a local hostname, another private VPN, or a
VPS. The bearer token authenticates requests but does not encrypt them.

- Use HTTP only on a trusted private LAN or encrypted VPN. Anyone able to inspect
  that traffic could read the bearer token and uploaded recording.
- Use HTTPS with a valid trusted certificate for a VPS, public DNS name, or any
  untrusted network.
- Never expose the gateway's plain HTTP port directly to the public internet.
- A self-signed HTTPS certificate must be explicitly trusted by iOS; a publicly
  trusted certificate is simpler and safer for a VPS.

## Full Access

The keyboard requests Full Access because the product coordinates a containing
app and a gateway the user runs. The extension does not record microphone audio,
inspect unrelated keystrokes, or use clipboard insertion. iOS still controls
whether a third-party keyboard is available in a field.

Typing intelligence does **not** need Full Access, and must not: a keyboard that
cannot type without it is not a keyboard. The one exception is the optional
Check grammar, which reaches the containing app through the App Group (see
above) and simply does nothing without Full Access. Without Full Access, completions,
corrections and predictions all still work; only learned words stop persisting,
and the Keyboard settings screen says so rather than pretending otherwise.
Keyboard haptics are also unavailable without it, because iOS gives an extension
no route to the Taptic Engine, and that is stated next to the switch.

## iOS keyboard

The iOS keyboard completes, corrects and predicts entirely on the device.

- **Where suggestions come from.** `UITextChecker` — the same dictionary iOS
  uses in every other app, in whatever languages the user has installed — plus a
  frequency-ordered English word list and bigram table shipped in the app
  bundle, the user's own text replacements and contact names via `UILexicon`,
  their custom words, and words the keyboard has learned. No network call is
  made for a suggestion, ever, including to a configured gateway.
- **What the keyboard reads.** The word being typed, which the keyboard tracks
  itself, and `documentContextBeforeInput` to reconcile that word after the
  cursor moves. iOS gives a keyboard extension no composing region, so this is
  the only way to know which word to replace. Neither is logged or stored.
  With Check grammar on, the last sentence or two of that context goes to the
  containing app after a pause, as described above.
- **Sensitive fields.** Suggestions, correction, prediction and learning are all
  switched off — not merely hidden — in password, new-password, one-time-code,
  card-number and number-pad fields.
- **Learned words.** Words typed three times without being undone, and words
  tapped in the suggestion row, are stored in the App Group on this iPhone,
  capped at 2 000 and evicted least-recently-used. They are never written to the
  system-wide dictionary that other apps read, never listed in the interface
  beyond a count, and are erased by "Reset learned words" or by deleting the app.
- **Diagnostics.** No typed character, candidate, or learned word is written to
  the diagnostic log or included in an export. The log's vocabulary is a closed
  set of state and lifecycle events with no free-text field, and a test asserts
  an export contains none of it.
- **Swipe typing** matches the traced path against the same on-phone word list
  and reads nothing from the field. **Emoji** search runs against a shipped CLDR
  annotation catalog; recents are stored in the App Group.
- **Transcript retention** is the user's choice — keep everything, 30 days, or
  7 days — under Settings → Privacy and permissions, alongside a way to delete
  any single transcript or all of them. Deleting all waits until a current
  dictation has finished, so live words cannot be rewritten during removal.
  If a requested deletion cannot finish,
  the app reports the error so remaining files can be retried. Automatic
  retention cleanup records a redacted diagnostic on failure and retries during
  later housekeeping. It also removes old preview sidecars left without a
  session record by an earlier interruption or app version.

## Android keyboard

The Android IME inserts through `InputConnection`. When inserting a finished
dictation, it reads at most one character before and after the cursor or selected
range to add spacing between adjacent words. That context stays in memory,
is never logged, and is not sent to the gateway. With Suggestions enabled, the
keyboard may call `getTextBeforeCursor(32)`
and `getTextAfterCursor(32)` in non-password fields so next-word guesses and
corrections have a token. That window stays in memory, is never logged, and is
not sent to the gateway. With Check grammar on, the keyboard also reads up to
600 characters before the cursor once the user pauses, and checks the last
sentence or two of it with the on-device grammar model in the same process;
that text is never logged, stored or sent anywhere. Swipe typing matches the
finger path against the same on-phone English word list and does not read the
field. Swipe and suggestions
are English only; the app does not download other keyboard language packs. The clipboard chip and
optional clipboard history read
clips only while the input view is showing; history stays on the phone. Neither
path is used to insert a transcript.

## Android floating mic (VocaPhoneX, x flavor)

The `x` sideload build (VocaPhoneX) replaces the keyboard with a floating
bubble. It requests two extra system permissions the shipped builds never
need:

- **Display over other apps** (`SYSTEM_ALERT_WINDOW`), to draw the mic bubble.
- **Accessibility service**, which the OS grants after an explicit in-system
  opt-in. The service reads focus events to know when an editable field is
  active and performs `ACTION_SET_TEXT` to place the finished transcript.
  Field reads are the same kind of context the keyboard sees; they stay on
  the phone, are never logged, and are not sent to the gateway. Password and
  other sensitive fields are excluded the same way, and apps the user lists
  under Settings → Floating mic never see the bubble.

Because insertion is `ACTION_SET_TEXT`, the transcript lands atomically and
does not go through any keyboard's composing state or clipboard.

## Usage statistics (Android)

Settings → Stats counts how much you have dictated. It is counts only: six
numbers — total words, transcriptions, recorded audio, the current and best day
streak, and the day of the most recent dictation — plus a word total for each of
the **seven most recent days** that have one. No transcript text and no audio.

They are written to an app-private DataStore file of their own, separate from the
file holding settings and the gateway token, so a damaged statistics file costs
counters rather than a working setup. `allowBackup="false"` applies to the whole
app, so they are not carried off the phone by Android backup or device transfer.
Nothing here is transmitted: no usage-reporting event carries any of it, and it
is absent from the diagnostics export, which stays a closed vocabulary of state
and lifecycle events.

**They deliberately outlive transcripts.** Deleting your history — one dictation
or all of it — does not reduce these counters, because they are the record of how
much you dictated rather than of what you said. The delete-all confirmation says
so. **Settings → Stats → Reset statistics** erases them, permanently and without
touching your transcripts, and uninstalling the app removes them with everything
else.

Only the seven displayed days are retained, so there is no longer-term history of
which days you dictated on. The streak counters are the exception, and they are
two integers rather than a diary.

## Per-device tokens

`VOCAGATEWAY_TOKEN` (or its token file) remains a permanent bootstrap credential
that always authenticates and cannot be revoked through the API — whoever
controls that file or environment variable can already read or rotate it
directly. The WebUI Settings tab and the Overview pairing card can both create
named, independently revocable tokens for specific devices. Only a SHA-256
digest of each is persisted (`app/tokens.py`); the plaintext is shown once, at
creation. Creating a device token from the pairing card immediately shows a QR
for it, so a new phone can scan its own credential instead of the shared
bootstrap token. The plaintext also stays cached in memory (never written to
disk) for the rest of that gateway process, so the pairing card's token
dropdown can still regenerate that same device's QR at a different address
without creating a duplicate token; a restart, or revoking the token, clears
it from that cache.

A gateway restart (a routine deploy/update, for example) never affects an
already-paired device: its token is validated by hash and keeps authenticating
exactly as before. The in-memory cache only controls whether *this session*
can redisplay that secret as a QR — losing it after a restart is expected and
harmless. Rotating a token (giving it a fresh secret so its QR can be shown
again) is the one action that actually breaks that device's existing pairing,
so treat it as opt-in, not routine maintenance. Revoking a device token
immediately rejects further requests carrying it without affecting the
bootstrap token or any other paired device.

## Stats sharing

Usage statistics remain on the phone unless the user explicitly taps a sharing
action on the Stats page. VocaPhone then creates a share card from the aggregate
counters. The X action places that image on the device clipboard and opens X's
composer with a prefilled post. The Share action hands the card and post text to
the system share sheet, where the user picks the destination app, and also
places the post text on the device clipboard. This is a user-directed share to
the chosen app; it is not telemetry and does not include recordings,
transcripts, gateway credentials, or audio.

## Usage reporting

**Off until the user turns it on.** Guided setup asks once, at the end, after a
working transcript rather than before; Settings can change the answer at any
time. Nothing is queued while the switch is off — not queued-and-discarded, so
turning it on later cannot deliver a backlog.

It reports to a self-hosted [Aptabase](https://github.com/aptabase/aptabase)
instance (AGPL-3.0) that VocaHQ runs at `telemetry.vocahq.com`. No third-party
analytics service is in the path, and no analytics SDK is linked into either
binary: the sender is about a hundred lines against Aptabase's documented ingest
API, in `android/…/telemetry/` and `ios/VocaPhoneApp/Telemetry/`.

### There is no identifier

Aptabase derives its anonymous user server-side from the request's IP address,
the User-Agent, and a per-app salt that is **discarded every 24 hours**. Nothing
identifying is stored on the phone — no install ID, no IDFV, no `ANDROID_ID`, no
advertising ID — and because the salt is thrown away, the same device on two
different days produces two unrelated hashes that nobody, including whoever
holds root on the server, can join back together.

That is why there is no "reset my reporting ID" button: there is no ID to reset.
The only client-side identifier is an in-memory session number that rotates after
an hour of inactivity and is never written to disk.

The consequence, stated plainly: there are no retention curves and no multi-day
funnels. The setup funnel is reconstructed from ratios of once-ever counters
(`first_dictation_ever` over `app_first_open`) rather than by following anyone.

### What is sent

A closed vocabulary, enforced by the type system rather than by review. Neither
platform's telemetry API has a parameter that accepts a string, so a call site
cannot pass a transcript, a URL or a token even by mistake; tests on both sides
fail the build if that stops being true. The model identifier is the one value
that begins life as a string, and both platforms pin it against the shipped
catalog before it can reach the network.

- Which setup step was reached, and whether setup finished
- Which transcription source was selected — on-device or gateway, never which
  gateway
- Which shipped on-device model was downloaded, and whether it completed
- Which shipped on-device model actually transcribed a dictation, and at which
  of the three accuracy settings. A gateway dictation reports `gateway` for
  both, because the gateway decides its own model and decoding and is never
  asked; anything outside the shipped catalog reports `unknown` rather than the
  value it was given
- Whether a dictation succeeded or failed, at which stage, and for what reason,
  drawn from a fixed list of causes
- Recording length **bucketed** (`<10s`, `10–30s`, `30–60s`, `60s+`), never exact
- App version, OS **major** version only, language subtag only (`en`, not
  `en-IN`), and whether it is a debug build

### What is never sent

Transcripts, audio, typed text, or any character count. The gateway's URL,
hostname, IP or bearer token. Model file paths. Device model, exact OS build,
region or timezone. Free text of any kind.

**Device model is deliberately absent**, unlike Aptabase's own SDKs, which send
it. Play Console and App Store Connect already report the device distribution for
every install, and model plus exact OS build plus locale is a usable fingerprint
at beta population sizes — which would undo most of what the daily salt rotation
achieves. Omitting it is the main reason the sender is hand-rolled.

**The model identifier is the one value with real cardinality**, and it is worth
being straight about that. The catalog is dozens of entries rather than the two
a source selection has, and several models are language-locked, so reporting one
softly implies what language somebody speaks. Two things keep this from mattering
much: the language subtag is already sent and says the same thing more directly,
and Aptabase's daily salt rotation means today's events cannot be joined to
tomorrow's whatever they contain. It is a real widening of the payload, not a
neutral one, and the honest summary is that it buys the ability to tell whether a
performance fix landed at the cost of a value that is not quite as inert as a
bucketed duration.

### Where it does not run

- **The iOS keyboard extension reports nothing and cannot.** The whole
  `VocaPhoneApp/Telemetry` directory is compiled into the containing app only,
  so the keyboard binary has no reporting code in it and its
  `PrivacyInfo.xcprivacy` keeps an empty `NSPrivacyCollectedDataTypes`. The
  Android IME holds the same line for parity.
- **The F-Droid flavour cannot report.** `BuildConfig.TELEMETRY` is a constant
  `false` there, so R8 strips the sender, the host, the app key and every
  control that could switch reporting on. Scanning the release APK's dex finds
  no host, no ingest path, no credential header and no switch; what remains is
  an unreachable queue wired to a no-op sink.
- **Debug and source builds never transmit**, whatever the default says.

### Checking it rather than trusting it

Settings → Privacy → Usage reporting → "See exactly what's sent" renders the literal JSON
that the next flush would POST, `systemProps` included — not a summary of it. If
a field is ever added to the payload, it appears on that screen without anyone
having to remember to describe it.

The same screen shows content-free delivery counters — how many events were
recorded, how many were sent, and what the last attempt did. They carry counts
and an outcome, never an event name or a property value. They exist because the
delivery path swallows every failure by design, which is right in production and
leaves nobody — user or developer — able to tell "delivered" from "never
recorded" when something looks wrong.

Note what that line does **not** claim. Aptabase's ingest answers `200` to any
well-formed batch, including one carrying an unknown app key, so a successful
send means the server accepted the request and not that it stored anything. The
dashboard is the only authority on that, and the wording on screen says so.

Turning reporting off sends one final `telemetry_disabled` event before the
switch takes effect, then discards the queue. That is stated next to the switch:
an opt-out event discovered by packet capture would be worse than not knowing the
opt-out rate.

### On the server

By design: the reverse proxy passes the client address because Aptabase needs it
to compute the daily rotating hash, the ingest path's access logs do not retain
it, and events age out on a ClickHouse TTL.

By design is not the same as verified, and the difference is the entire reason
this backend is self-hosted. These are claims about infrastructure rather than
about code in this repository, so no amount of reading this tree establishes
them — and a claim nobody has checked is exactly the vendor promise self-hosting
was meant to replace. Each is listed below with what would establish it and
whether that has been done. The table is meant to be uncomfortable to read while
it still says "not yet verified".

| Claim | What establishes it | Status |
| --- | --- | --- |
| Aptabase receives the client address but persists no raw IP | Inspect the ClickHouse events schema and a sample row; confirm no column holds an address | Not yet verified |
| The ingest path's access logs do not record addresses | Read the proxy configuration for the ingest location | Not yet verified |
| Events age out on a ClickHouse TTL | Read the `TTL` clause off the events table. The intended retention is 180 days | Not yet verified |
| The ingest path is rate limited | Read the proxy configuration | Not in place yet |

`telemetry/README.md` carries the exact commands for each row. When one is done,
replace its status with the date it was checked — a date is the only form of
this claim that means anything.

The ingest key compiled into the apps (`A-SH-…`) is deliberately not a secret.
It can append events and nothing else — it cannot read the dashboard, change an
app, or reach any other endpoint — and it ships inside every binary, so it is
extractable from any store download. Keeping it out of the repository would hide
it from contributors and from nobody else. The exposure it does create is
someone posting junk events to skew the beta numbers, which is a data-quality
problem rather than a privacy one. The answer to it is rate limiting the ingest
path at the proxy, which is not in place yet, and rotating the key if it is ever
abused. It is unrelated
to the gateway bearer token, which is a real secret and lives in the iOS
Keychain and the Android Keystore.

## Usage statistics (iOS)

Counters for the Stats screen in Settings: total words, total dictations, total
recorded seconds, a current and best streak, and words, sessions, and recorded
time for each of the last seven active days. The screen fills quiet dates into
its seven-calendar-day chart without storing additional events.

- **Counts, not words.** No transcript text and no audio is stored. A dictation
  contributes a number, and the number cannot be turned back into what was said.
- **Never leaves the device.** Nothing here is sent to a gateway, reported as
  telemetry, or included in the diagnostics export.
- **Written where the dictation lands.** The keyboard extension appends one
  small file per inserted dictation to the App Group; the app folds those into a
  summary when the Stats screen is opened.
- **Outside transcript retention, deliberately.** The files live in `usage/`,
  beside `sessions/` rather than inside it, so deleting your transcripts — or
  running a 7- or 30-day retention setting — keeps your lifetime totals. The
  reverse also holds: resetting statistics does not touch your transcripts.
- **Reset at any time**, from the Stats screen. This deletes the summary and any
  pending events permanently.

Only dictations that were actually inserted are counted. A transcript that is
produced and then abandoned never becomes a statistic.

## Diagnostics export

The authenticated WebUI Settings tab and `uv run vocaphone-diagnostics` can export a
redacted snapshot for a bug report: version, engine/model status, hardware and
dependency detection, setup checklist, in-memory operational counters, and
persistent configuration. Filesystem paths under the operator's home directory are
rewritten to `~`. It never includes the bearer token, recording audio, transcript
text, or session identifiers — see `app/diagnostics.py`.

## Remaining threats before distribution

- Review model and FFmpeg supply-chain provenance.
- Add dependency vulnerability and secret scanning in CI.
- Confirm tailnet ACLs restrict gateway access to the user's devices.
- Revisit transcript retention and lock-screen exposure with the user.
