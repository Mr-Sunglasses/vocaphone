# Privacy and threat model

## Data flow

The containing iPhone app records only after an explicit Start action. It keeps
recoverable audio in the App Group container, sends it to the configured
bearer-authenticated gateway over HTTP or HTTPS, and deletes the iPhone copy
after a transcript is safely stored. HTTPS or an encrypted private network is
recommended so the recording and token are protected in transit.

When Quick Dictation is enabled, the containing app may keep microphone input
active for up to 10 minutes so later keyboard actions do not need another app
handoff. The system's orange microphone indicator remains visible. Audio buffers
captured while waiting are discarded in memory: they are not written to disk,
placed in shared state, or uploaded. Only audio after an explicit Dictate action
is saved for transcription. The user can turn Quick Dictation off in the app.

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
cannot type without it is not a keyboard. Without Full Access, completions,
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
  any single transcript or all of them.

## Android keyboard

The Android IME inserts through `InputConnection`. Dictation does not read the
field. With Suggestions enabled, the keyboard may call `getTextBeforeCursor(32)`
and `getTextAfterCursor(32)` in non-password fields so next-word guesses and
corrections have a token. That window stays in memory, is never logged, and is
not sent to the gateway. Swipe typing matches the finger path against the same
on-phone English word list and does not read the field. Swipe and suggestions
are English only; the app does not download other keyboard language packs. The clipboard chip and
optional clipboard history read
clips only while the input view is showing; history stays on the phone. Neither
path is used to insert a transcript.

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

Settings → Usage reporting → "See exactly what's sent" renders the literal JSON
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
