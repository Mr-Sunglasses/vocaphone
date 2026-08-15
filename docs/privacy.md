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
- No analytics or third-party transcription
- No ordinary logging of audio, transcripts, tokens, or private endpoint values
- In-memory operational metrics contain only counts, queue activity, stage
  timings, real-time factor, peak process memory, and process uptime; they reset
  on restart and include no transcript or session data
- Docker Compose mounts the bearer token as a secret instead of a container
  environment variable; `/data` is the only persistent application volume

The Compose source token is normally stored in the host-only `server/.env` file
before Docker mounts it at `/run/secrets/vocaphone_token`. Keep that file at mode
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

`VOCAPHONE_TOKEN` (or its token file) remains a permanent bootstrap credential
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
