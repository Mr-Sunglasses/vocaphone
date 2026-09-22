# Security policy

## Supported versions

| Channel | Security support |
| --- | --- |
| Android | Latest stable Google Play / GitHub `android/v*` release |
| Android prereleases | Latest prerelease only; update to stable when available |
| iOS | Latest available TestFlight build |
| Source builds | Current `main`; rebuild after security fixes |

Older versions are not maintained as separate security branches. Fixes land on
`main` and are delivered in a new release for each affected supported platform.
Maintainers publish an advisory with affected versions, fixed versions, and
any interim mitigation; users should update through their installation channel.
Gateway vulnerabilities are coordinated privately with
[VocaGateway](https://github.com/VocaHQ/vocagateway/security/policy).

## Reporting a vulnerability

Do not open a public issue for suspected vulnerabilities involving microphone
access, recordings, transcripts, App Group data, bearer tokens, the Mac/Linux
gateway, or Tailscale exposure.

Prefer GitHub's private vulnerability reporting in the repository **Security**
tab: [Report a vulnerability](https://github.com/VocaHQ/vocaphone/security/advisories/new).
If that form is unavailable, email [hello@vocahq.com](mailto:hello@vocahq.com)
and request a private channel before sharing details.

Include the affected component, reproduction steps, impact, and any suggested
mitigation. Do not include real recordings, transcripts, tokens, private
tailnet hostnames, or other personal data in the initial report.

We aim to acknowledge reports within three business days. If there is no reply
within seven days, follow up at the email address above. We will
coordinate a fix and disclosure timeline based on severity and whether users
need to rotate tokens or rebuild clients.

Repository administrators triage secret-scanning and dependency alerts weekly,
and urgently when a credible active exposure is reported. For leaked credentials,
revoke or rotate first, audit use and affected releases, then remove the exposed
value. Deleting a commit does not revoke a credential. See
[dependency maintenance](docs/dependency-maintenance.md) for ownership and cadence.

For non-security support questions, see [SUPPORT.md](SUPPORT.md).
