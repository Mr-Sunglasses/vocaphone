# Decisions and open setup choices

## Final naming decisions (v0.3.0)

The **Local Flow** working name has been replaced with **vocaphone** across all
identifiers. The following are the final identifiers in use:

| Scope | Final identifier |
| --- | --- |
| Product / display | **vocaphone** (lowercase prose) |
| Client code symbols | **VocaPhone** (PascalCase) |
| Gateway CLI entry points | `vocaphone-server`, `vocaphone-status`, `vocaphone-diagnostics`, `vocaphone-cleanup` |
| Gateway env prefix | `VOCAGATEWAY_` |
| Gateway config/data paths | `~/.config/vocagateway/`, `~/.local/share/vocagateway/` |
| macOS logs | `~/Library/Logs/Vocaphone/` |
| iOS app bundle ID | `com.vocahq.vocaphone` |
| iOS keyboard bundle ID | `com.vocahq.vocaphone.keyboard` |
| iOS Live Activity bundle ID | `com.vocahq.vocaphone.liveactivity` |
| iOS App Group | `group.com.vocahq` |
| iOS development team | `92962VK378` |
| iOS URL scheme | `vocaphone://dictate` |
| Android application ID | `com.vocahq.vocaphone` |
| LaunchAgent label | `com.vocahq.vocaphone.gateway` |
| systemd unit | `com.vocahq.vocaphone.gateway.service` |
| Docker image tag | `vocaphone-gateway` |
| Docker volume | `vocagateway_vocagateway-data` |

Register the bundle identifiers and App Group on team `92962VK378`. The older
group (`group.com.vocahq.vocaphone`) belongs to another team and cannot be
reused here.

Native gateway startups migrate a missing vocaphone bootstrap token (and
WebUI config) from the Local Flow paths once, and the LaunchAgent/systemd
install helpers remove the obsolete Local Flow units. Everything else remains
a documented hard cutover — see
[deployment.md](deployment.md#migrating-from-the-local-flow-working-name-v030).

## Reversed: anonymous usage reporting (August 2026)

The 0.1.0 beta plan called the absence of analytics and crash reporting "correct
and non-negotiable". That position is deliberately reversed here, and the
reversal is recorded rather than left to be discovered in a diff.

**What changed.** The beta has no feedback channel that does not require the user
to write an email, so the one question it cannot answer is where setup breaks for
people who never file a bug.

**What did not change.** No third-party analytics service, no analytics SDK in
either binary, nothing sent by default, and nothing sent that is not a counter.

| Choice | Decision | Why |
| --- | --- | --- |
| Backend | Self-hosted Aptabase (AGPL-3.0) at `telemetry.vocahq.com` | Purpose-built for privacy-first mobile analytics; three containers rather than PostHog's eight-service stack; no vendor in the data path |
| Client | Hand-rolled against the documented ingest API, not the MIT SDK | The SDK auto-sends `deviceModel` and a full `osVersion`; omitting them is a one-line decision when you own the request and a fork when you do not. Also keeps "no analytics SDK" literally true |
| Identity | None. Aptabase derives an anonymous user from a salt it discards every 24 hours | Nothing stored on the phone, and two days of events cannot be joined. Costs all retention and multi-day funnel analysis, which is accepted |
| Default | Opt-in, asked at the end of guided setup | Not a legal requirement — with no device-stored identifier the ePrivacy consent hook does not apply — but this audience installed a self-hosted dictation keyboard, and a default-on network call spends trust that took a release to earn |
| F-Droid | Compiled out: no sender, host, credential or switch survives R8, verified by scanning the release dex | Keeps the listing clear of the `Tracking` anti-feature without relying on a runtime check, and leaves the reproducible build's dependency graph unchanged |
| iOS keyboard | Reports nothing; the code is not in the extension's target | A Full Access keyboard that can open a socket is the scariest thing this product could ship, whatever is in the packet |

Full detail in [privacy.md](privacy.md#usage-reporting); the backend that
receives it, and what has and has not been verified about it, is in
[`telemetry/`](../telemetry/README.md).

## Implemented assumptions

These are changeable implementation defaults, not confirmed product decisions:

| Choice | Current assumption | Why |
| --- | --- | --- |
| Minimum iOS | iOS 17.0 | Supports the chosen SwiftUI and audio APIs |
| Recording | WAV from one persistent `AVAudioEngine` input | Avoids losing background microphone readiness between dictations; FFmpeg normalizes it on the Mac |
| Quick Dictation | Enabled; ready window of 10 minutes (default), 20 minutes, or until the app is closed | Reduces app switching while bounding battery and microphone exposure. The Live Activity's stop button pauses the current window only; the next launch arms a new one. Installs that arrive with it already off — which an older build could do on one tap — are asked once on Home, never switched back on silently |
| Language | Automatic plus Arabic, English, Spanish, Japanese, Korean, Mandarin Chinese, Ukrainian, Russian, and Vietnamese | Automatic follows the selected gateway model; explicit choices must match it |
| Output mode | Raw | Avoids unconfirmed cleanup by default |
| Audio retention | Delete on success; keep failures 24 hours | Privacy with retry recovery |
| Transcript history | Shared session records only | Full product history remains a later choice |
| Native listener | `0.0.0.0:8765` by default; loopback recommended with Serve | Supports LAN setup while allowing a smaller Tailscale-only exposure |
| Container publication | Host loopback port 8765 by default | Keeps Docker private behind Tailscale Serve unless LAN access is intentional |
| Initial engine | `auto`: VocaMac, Handy, WhisperKit, MLX Audio, sherpa-onnx, faster-whisper, then `whisper.cpp` | Uses what is actually runnable while preserving an explicit WebUI choice; the two optional desktop apps come first because their models are already on disk |
| Docker engines | Portable sherpa-onnx INT8, OpenBLAS `whisper.cpp`, persistent faster-whisper CPU INT8, and multilingual Moonshine | Keeps the default portable across Linux `amd64` and `arm64`; separate native CPU, CUDA, and Vulkan profiles opt into host-specific acceleration |

## Must be confirmed before physical-device acceptance

- Whether iOS 17.0 is the desired minimum
- Mac availability and sleep policy
- Whether mixed Hindi/English should be added through a separate multilingual model
- Default native and container models after representative latency, accuracy,
  memory, and disk benchmarks
- Transcript history policy
- Failed-audio retry window
- Whether local cleanup should remain opt-in
