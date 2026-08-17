# vocaphone — one entry point for three applications.
#
# Each application owns its own justfile, because the three share no toolchain
# at all. This file only aggregates them, so both of these work:
#
#   cd gateway && just run      # what you type while working on one app
#   just gateway run            # the same recipe, from anywhere in the repo
#   just --list gateway         # that app's recipes on their own
#
# gateway/ is the VocaHQ/vocagateway git submodule. Init it before gateway recipes:
#   git submodule update --init --recursive
#
# The parent repo records a fixed gateway SHA for reproducible clones and
# shipping. Locally, `just gateway-sync` moves the working tree to the tip of
# the branch named in .gitmodules (main); that does not change the pin until
# you `git add gateway && git commit`. `just gateway-pin-status` shows pin vs
# working tree vs remote tip.
#
# mod? makes the module optional so a clone without submodules can still run
# `just`, `just ios …`, `just android …`, and `just doctor`. Required `mod`
# would fail at parse time before any recipe (including the ci skip) can run.
#
# Recipes here are the cross-cutting ones: they fan out over all three.

mod android
mod ios
mod? gateway

# List the modules and the cross-cutting recipes.
default:
    @{{ just_executable() }} --list --unsorted

# Move gateway/ to the tip of the branch tracked in .gitmodules (usually main).
# For local gateway work only — does not commit a pin bump.
[group('gateway')]
gateway-sync:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -e gateway/.git ] && [ ! -f gateway/.git ]; then
        echo "gateway/ submodule is not checked out." >&2
        echo "Run: git submodule update --init --recursive" >&2
        exit 1
    fi
    # --remote follows submodule.<name>.branch from .gitmodules (main).
    git submodule update --init --remote --merge gateway
    echo
    '{{ just_executable() }}' gateway-pin-status

# Compare the recorded pin, the local gateway/ checkout, and origin tip.
[group('gateway')]
gateway-pin-status:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -e gateway/.git ] && [ ! -f gateway/.git ]; then
        echo "gateway/ submodule is not checked out."
        echo "Run: git submodule update --init --recursive"
        exit 0
    fi

    pin=$(git rev-parse --verify HEAD:gateway 2>/dev/null || true)
    if [ -z "${pin}" ]; then
        echo "No submodule pin recorded on HEAD (gateway/ not in this commit)."
        exit 0
    fi

    work=$(git -C gateway rev-parse HEAD)
    branch=$(git config -f .gitmodules --get submodule.gateway.branch || echo main)
    git -C gateway fetch --quiet origin "${branch}" 2>/dev/null || true
    remote=$(git -C gateway rev-parse "origin/${branch}" 2>/dev/null || echo "")

    short() { git -C gateway rev-parse --short "$1" 2>/dev/null || echo "$1"; }

    echo "pin (this repo HEAD):  $(short "${pin}")  ${pin}"
    echo "working tree:          $(short "${work}")  ${work}"
    if [ -n "${remote}" ]; then
        echo "origin/${branch}:          $(short "${remote}")  ${remote}"
    else
        echo "origin/${branch}:          (unavailable — fetch failed or no network)"
    fi

    if [ "${work}" = "${pin}" ]; then
        echo "status: working tree matches the recorded pin"
    else
        echo "status: working tree differs from the pin (local only until you commit)"
        echo "        to ship a bump: git add gateway && git commit"
    fi
    if [ -n "${remote}" ] && [ "${work}" != "${remote}" ]; then
        echo "note:   working tree is not at origin/${branch}; just gateway-sync to update"
    fi
    if [ -n "${remote}" ] && [ "${pin}" != "${remote}" ]; then
        echo "note:   recorded pin is behind (or ahead of) origin/${branch}"
    fi

# Run every application's checks, skipping any whose toolchain is absent.
ci:
    #!/usr/bin/env bash
    # Nobody has all three toolchains installed at once — the iOS leg cannot run
    # off macOS — so a missing one is reported and skipped rather than failed.
    # Whatever can run, runs, and the exit code reflects only those legs.
    set -uo pipefail
    status=0
    just_bin='{{ just_executable() }}'

    # The brand rules need nothing but python3, so this leg always runs.
    echo "==> brand"
    python3 assets/generate.py --check || status=1
    echo

    echo "==> gateway"
    if [ ! -f gateway/justfile ]; then
        echo "skipped  gateway submodule not checked out (git submodule update --init)"
    elif command -v uv >/dev/null 2>&1; then
        # The gateway follows the django-modern-rest convention, where `test`
        # is the run-everything recipe and `unit` is just pytest.
        "${just_bin}" gateway::test || status=1
    else
        echo "skipped  uv is not installed"
    fi

    echo
    echo "==> android"
    if "${just_bin}" android::_sdk >/dev/null 2>&1; then
        "${just_bin}" android::ci || status=1
    else
        echo "skipped  no Android SDK on this machine"
    fi

    echo
    echo "==> ios"
    if [ "$(uname -s)" = "Darwin" ] && command -v xcodegen >/dev/null 2>&1; then
        "${just_bin}" ios::ci || status=1
    else
        echo "skipped  needs macOS with xcodegen installed"
    fi

    exit "${status}"

# Report the toolchain state of all three applications.
doctor:
    #!/usr/bin/env bash
    # Always exits 0: not having the Android SDK on a machine you only write
    # Swift on is a fact, not a fault. Each application's own `just doctor` is
    # the one that fails when something it needs is missing.
    set -uo pipefail
    just_bin='{{ just_executable() }}'
    if [ -f gateway/justfile ]; then
        echo "==> gateway"
        "${just_bin}" gateway::doctor || true
        echo
    else
        echo "==> gateway"
        echo "skipped  gateway submodule not checked out (git submodule update --init)"
        echo
    fi
    for app in android ios; do
        echo "==> ${app}"
        "${just_bin}" "${app}::doctor" || true
        echo
    done
