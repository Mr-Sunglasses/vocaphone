# Security policy

## Supported version

The latest code on `main` is the only version currently receiving security and
privacy fixes. vocaphone has not had a public production release.

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

You should receive an acknowledgment within a few business days. We will
coordinate a fix and disclosure timeline based on severity and whether users
need to rotate tokens or rebuild clients.

For non-security support questions, see [SUPPORT.md](SUPPORT.md).
