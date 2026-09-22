---
title: Maintain dependencies
description: Review and update VocaPhone dependencies, submodules, native binaries, and tools.
---

# Maintain dependencies

Use this page during routine maintenance or when a dependency update changes a
native runtime, build tool, or release artifact. Every update needs a review of
the source, the pin, the affected platform, and the appropriate quality gate.

The administrators in [GOVERNANCE](https://github.com/VocaHQ/vocaphone/blob/main/GOVERNANCE.md) own weekly alert triage
and a monthly dependency review. Security fixes take priority over routine
update batching. Aim to resolve critical alerts immediately and other confirmed
high/medium vulnerabilities within 30 days; record mitigations or exceptions
privately when disclosure would put users at risk.

| Dependency | Update process |
| --- | --- |
| GitHub Actions, including composite actions | Dependabot SHA updates; review upstream changes and workflow permissions |
| Android Gradle dependencies | Dependabot plus dependency-graph submission from reviewed `main`; run Android CI and assess runtime changes on a device |
| Git submodules | Dependabot proposes pins; gateway changes stay in vocagateway, and whisper.cpp is never edited here |
| iOS Swift packages | Dependabot discovers Xcode package references and lockfile; reconcile proposed updates with `ios/project.yml`, regenerate Xcode, run iOS CI |
| Android Sherpa / ONNX native binaries | Follow the provenance and rebuild instructions in `android/app/src/full/jniLibs/README.md`; inspect upstream advisories and validate both ABIs |
| Downloadable models | Review upstream source, license, immutable revision, size and hashes when changing catalog pins; models are downloaded separately and are not bundled app dependencies |
| Downloaded CI tools | Pin version and checksum where available; review actionlint and Semgrep during monthly maintenance |

The welcome automation is a local snapshot of the VocaHQ shared workflow so its
internal action is pinned too. Review upstream welcome changes during monthly
maintenance; the source revision is recorded in the workflow header.

Dependabot supports Xcode package references, but does not own our XcodeGen
source of truth. When a bot proposes a Swift update, a maintainer must also
update any corresponding pin in `ios/project.yml` and regenerate the project.
The stale-project check must pass before merge. Review exact native/runtime
pins monthly even when the bot cannot propose an update within their constraints.

For every native or Swift update, review release notes, advisories, license and
notice requirements, supported architectures, and transitive dependencies.
Do not auto-merge binary runtime updates. Checksums identify downloaded bytes;
they do not establish that the upstream build was trustworthy.

Android releases publish CycloneDX inventories for the resolved full and fdroid
runtime graphs, supplemented with native library versions, source revisions,
and binary hashes. Update `tools/native-dependencies.json` alongside the native
runtime provenance README when replacing binaries. Transitive native files whose
origins are not independently mapped are explicitly marked in the inventory.
These describe bundled dependencies; downloaded models and
the optional separate gateway are excluded. See [release VocaPhone](../how-to/release.md) for
provenance verification. An SBOM is an inventory, not a vulnerability clearance
or a substitute for distributing required third-party license notices.
