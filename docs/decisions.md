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
| Language | Automatic plus Arabic, English, Spanish, Japanese, Korean, Mandarin Chinese, Ukrainian, and Vietnamese | Automatic follows the selected gateway model; explicit choices must match it |
| Output mode | Raw | Avoids unconfirmed cleanup by default |
| Audio retention | Delete on success; keep failures 24 hours | Privacy with retry recovery |
| Transcript history | Shared session records only | Full product history remains a later choice |
| Native listener | `0.0.0.0:8765` by default; loopback recommended with Serve | Supports LAN setup while allowing a smaller Tailscale-only exposure |
| Container publication | Host loopback port 8765 by default | Keeps Docker private behind Tailscale Serve unless LAN access is intentional |
| Initial engine | `auto`: VocaMac, Handy, WhisperKit, MLX Audio, sherpa-onnx, faster-whisper, then `whisper.cpp` | Uses what is actually runnable while preserving an explicit WebUI choice; the two optional desktop apps come first because their models are already on disk |
| Docker engines | Portable sherpa-onnx INT8, OpenBLAS `whisper.cpp`, persistent faster-whisper CPU INT8, and multilingual Moonshine | Keeps the default portable across Linux `amd64` and `arm64`; separate native CPU, CUDA, and Vulkan profiles opt into host-specific acceleration |

## Must be confirmed before physical-device acceptance

- Final product name, bundle identifiers, Apple team, and App Group
- Whether iOS 17.0 is the desired minimum
- Mac availability and sleep policy
- Whether mixed Hindi/English should be added through a separate multilingual model
- Default native and container models after representative latency, accuracy,
  memory, and disk benchmarks
- Transcript history policy
- Failed-audio retry window
- Whether local cleanup should remain opt-in

Do not treat the current placeholder identifiers as production identifiers.
