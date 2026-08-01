# Privacy and threat model

## Data flow

The containing iPhone app records only after an explicit Start action. It keeps
recoverable audio in the App Group container, sends it to the user's
bearer-authenticated Mac gateway through tailnet-only HTTPS, and deletes the
iPhone copy after a transcript is safely stored.

When Quick Dictation is enabled, the containing app may keep microphone input
active for up to 10 minutes so later keyboard actions do not need another app
handoff. The system's orange microphone indicator remains visible. Audio buffers
captured while waiting are discarded in memory: they are not written to disk,
placed in shared state, or uploaded. Only audio after an explicit Dictate action
is saved for transcription. The user can turn Quick Dictation off in the app.

The Mac stores randomized audio names under its private data directory. On
success, original and normalized audio are deleted by default. Failed and
abandoned sessions remain for the retry window (24 hours by default), after
which `localflow-cleanup` removes them. SQLite stores lifecycle metadata and the
result needed for idempotent retry.

## Security controls

- Configurable gateway binding, with loopback recommended for private deployments
- Tailscale Serve private ingress over a loopback listener; no Funnel
- Independent high-entropy bearer token
- Token stored in an iPhone Keychain item and a mode-600 Mac file
- Strict upload types, byte limits, duration limits, and one transcription slot
- FFmpeg and `whisper.cpp` invoked with argument arrays, never a shell
- Opaque file references and canonical server-owned paths
- No analytics or third-party transcription
- No ordinary logging of audio, transcripts, tokens, or private endpoint values
- In-memory operational metrics contain only counts, timings, queue activity, and
  process uptime; they reset on restart and include no transcript or session data
- Docker Compose mounts the bearer token as a secret instead of a container
  environment variable; `/data` is the only persistent application volume

The Compose source token is normally stored in the host-only `server/.env` file
before Docker mounts it at `/run/secrets/localflow_token`. Keep that file at mode
`600`, exclude it from backups shared with other people, and never commit it.

## Full Access

The keyboard requests Full Access because the product coordinates a containing
app and the user's Mac. The extension does not record microphone audio, inspect
unrelated keystrokes, or use clipboard insertion. iOS still controls whether a
third-party keyboard is available in a field.

## Remaining threats before distribution

- Review model and FFmpeg supply-chain provenance.
- Add dependency vulnerability and secret scanning in CI.
- Confirm tailnet ACLs restrict gateway access to the user's devices.
- Review diagnostics export before implementing it.
- Revisit transcript retention and lock-screen exposure with the user.
