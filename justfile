# vocaphone — one entry point for three applications.
#
# Each application owns its own justfile, because the three share no toolchain
# at all. This file only aggregates them, so both of these work:
#
#   cd server && just run       # what you type while working on one app
#   just server run             # the same recipe, from anywhere in the repo
#   just --list server          # that app's recipes on their own
#
# server/ is the VocaHQ/vocagateway git submodule. Init it before server recipes:
#   git submodule update --init --recursive
#
# The parent repo records a fixed gateway SHA for reproducible clones and
# shipping. Locally, `just server-sync` moves the working tree to the tip of
# the branch named in .gitmodules (main); that does not change the pin until
# you `git add server && git commit`. `just server-pin-status` shows pin vs
# working tree vs remote tip.
#
# mod? makes the module optional so a clone without submodules can still run
# `just`, `just ios …`, `just android …`, and `just doctor`. Required `mod`
# would fail at parse time before any recipe (including the ci skip) can run.
#
# Recipes here are the cross-cutting ones: they fan out over all three.

mod android
mod ios
mod? server

# List the modules and the cross-cutting recipes.
default:
    @{{ just_executable() }} --list --unsorted

# Move server/ to the tip of the branch tracked in .gitmodules (usually main).
# For local gateway work only — does not commit a pin bump.
[group('server')]
server-sync:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -e server/.git ] && [ ! -f server/.git ]; then
        echo "server/ submodule is not checked out." >&2
        echo "Run: git submodule update --init --recursive" >&2
        exit 1
    fi
    # --remote follows submodule.<name>.branch from .gitmodules (main).
    git submodule update --init --remote --merge server
    echo
    '{{ just_executable() }}' server-pin-status

# Compare the recorded pin, the local server/ checkout, and origin tip.
[group('server')]
server-pin-status:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -e server/.git ] && [ ! -f server/.git ]; then
        echo "server/ submodule is not checked out."
        echo "Run: git submodule update --init --recursive"
        exit 0
    fi

    pin=$(git rev-parse HEAD:server 2>/dev/null || true)
    if [ -z "${pin}" ]; then
        echo "No submodule pin recorded on HEAD (server/ not in this commit)."
        exit 0
    fi

    work=$(git -C server rev-parse HEAD)
    branch=$(git config -f .gitmodules --get submodule.server.branch || echo main)
    git -C server fetch --quiet origin "${branch}" 2>/dev/null || true
    remote=$(git -C server rev-parse "origin/${branch}" 2>/dev/null || echo "")

    short() { git -C server rev-parse --short "$1" 2>/dev/null || echo "$1"; }

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
        echo "        to ship a bump: git add server && git commit"
    fi
    if [ -n "${remote}" ] && [ "${work}" != "${remote}" ]; then
        echo "note:   working tree is not at origin/${branch}; just server-sync to update"
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

    echo "==> server"
    if [ ! -f server/justfile ]; then
        echo "skipped  server submodule not checked out (git submodule update --init)"
    elif command -v uv >/dev/null 2>&1; then
        # The gateway follows the django-modern-rest convention, where `test`
        # is the run-everything recipe and `unit` is just pytest.
        "${just_bin}" server::test || status=1
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
    if [ -f server/justfile ]; then
        echo "==> server"
        "${just_bin}" server::doctor || true
        echo
    else
        echo "==> server"
        echo "skipped  server submodule not checked out (git submodule update --init)"
        echo
    fi
    for app in android ios; do
        echo "==> ${app}"
        "${just_bin}" "${app}::doctor" || true
        echo
    done
