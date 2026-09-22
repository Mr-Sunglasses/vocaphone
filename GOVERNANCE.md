# Project governance

VocaPhone is maintained by VocaHQ. Decisions and their rationale belong in
public issues or pull requests, except security reports and personal matters.

## Maintainers and decisions

Repository administrators [@Mr-Sunglasses](https://github.com/Mr-Sunglasses)
and [@jatinkrmalik](https://github.com/jatinkrmalik) share responsibility for
Android, iOS, shared assets, security triage, and releases. Either covers the
other's absence. Review routing is recorded in [.github/CODEOWNERS](.github/CODEOWNERS).
Current maintain-role collaborators are @sesav, @neha-nupoor, and
@egoshingeorgii-eng; repository permissions remain the authoritative access list.

Discuss substantial changes in an issue before implementing them. Maintainers
seek agreement based on user needs, privacy, platform constraints, and the cost
of maintenance. If agreement is not possible, an administrator records the final
decision and rationale. Contributors can ask the other administrator to review
a disputed decision. Conduct concerns use [the code of conduct](CODE_OF_CONDUCT.md).

Changes go through a focused PR, applicable CI, and an independent review.
Resolve review conversations before merging. Release and workflow changes need
code-owner review. Do not approve your own PR or use administrator bypass as a
routine substitute for checks. Emergency bypass is limited to a PR, with the
reason recorded there and follow-up review by the other administrator.

## Becoming a maintainer

Contributors can request maintainer responsibility after sustained useful
contributions and reviews. Administrators consider judgment, responsiveness,
privacy awareness, and willingness to support an area, then record agreed scope
in a PR to this document. Start with the least access necessary. No donation,
employment relationship, or contribution count guarantees a role.

Before an extended absence, nominate the other maintainer as contact. Review
access and this roster quarterly and remove access no longer needed. Signing
credentials stay in GitHub secrets; never transfer them through issues or chat.

## Current priorities

The immediate priorities are reliable recording and insertion, clear onboarding,
accurate platform documentation, and maintainable on-device engines. The
[issue tracker](https://github.com/VocaHQ/vocaphone/issues) is the live backlog;
an open feature request is not a delivery promise. See
[starter contributions](docs/how-to/contribute.md) for bounded entry points.
