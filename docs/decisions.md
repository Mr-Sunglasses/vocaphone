# Decisions and open setup choices

## Implemented assumptions

These are changeable implementation defaults, not confirmed product decisions:

| Choice | Current assumption | Why |
| --- | --- | --- |
| Product name | Local Flow | Codename from `Plan.md` |
| Minimum iOS | iOS 17.0 | Supports the chosen SwiftUI and audio APIs |
| App bundle ID | `com.example.localflow` | Placeholder that builds unsigned |
| Keyboard bundle ID | `com.example.localflow.keyboard` | Placeholder |
| App Group | `group.com.example.localflow` | Placeholder |
| Recording | WAV from one persistent `AVAudioEngine` input | Avoids losing background microphone readiness between dictations; FFmpeg normalizes it on the Mac |
| Quick Dictation | Enabled, 10-minute ready window | Reduces app switching while bounding battery and microphone exposure |
| Language | Automatic | No first-release language was confirmed |
| Output mode | Raw | Avoids unconfirmed cleanup by default |
| Audio retention | Delete on success; keep failures 24 hours | Privacy with retry recovery |
| Transcript history | Shared session records only | Full product history remains a later choice |
| Gateway port | Loopback TCP 8765 | Private Tailscale Serve ingress |
| Initial engine | Handy CLI, auto-detected | Reuses the installed Canary model and Metal runtime |

## Must be confirmed before physical-device acceptance

- Final product name, bundle identifiers, Apple team, and App Group
- Physical iPhone model and iOS version
- Whether iOS 17.0 is the desired minimum
- Mac availability and sleep policy
- First-release languages and mixed Hindi/English requirements
- Default Handy/Whisper model after representative benchmarks; Canary currently
  covers English, German, Spanish, and French, not Hindi
- Transcript history policy
- Failed-audio retry window
- Whether local cleanup should remain opt-in

Do not treat the current placeholder identifiers as production identifiers.
