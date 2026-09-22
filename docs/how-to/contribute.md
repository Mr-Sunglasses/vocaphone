---
title: Find a starter contribution
description: Choose a small VocaPhone contribution with a clear acceptance boundary.
---

# Find a starter contribution

Use the repository [contributing guide](https://github.com/VocaHQ/vocaphone/blob/main/CONTRIBUTING.md)
for setup, worktrees, checks, and pull requests. The entries below are small
starting points with an explicit acceptance boundary. Ask in the linked issue
before starting so two contributors do not take the same work.

## Choose an entry point

| Issue | Scope and acceptance | Validation |
| --- | --- | --- |
| [#304: website accuracy](https://github.com/VocaHQ/vocaphone/issues/304) | Address the specific status, offline wording, and color inconsistencies in the report. Confirm current release facts first; preserve real screenshots and optional self-hosted gateway wording. | `cd web && npm run check`; inspect desktop and mobile widths |
| [#299: tile close control](https://github.com/VocaHQ/vocaphone/issues/299) | Agree the smallest UI change with a maintainer first; make leaving tile view and cancelling transcription distinguishable. Preserve cancellation and a discoverable way to leave tile view. | Read `android/AGENTS.md`; `just android ci`; report physical-device sequence |

The website issue is suitable as a first contribution. The Android issue is a
`help wanted` task for someone with an Android device and familiarity with UI
state. Neither requires a model engine rewrite or gateway change.

## Keep this page current

Maintainers review these entry points during weekly triage: remove completed
items, add small reproducible tasks, and keep `good first issue` and `help wanted`
labels aligned with actual scope. Acknowledge new reports within a week when
possible, and record whether a request is accepted, needs information, or is
outside current scope. Keep durable answers in GitHub Discussions or docs.
