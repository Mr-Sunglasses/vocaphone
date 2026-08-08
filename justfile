# vocaphone — one entry point for three applications.
#
# Each application owns its own justfile, because the three share no toolchain
# at all. This file only aggregates them, so both of these work:
#
#   cd server && just run       # what you type while working on one app
#   just server run             # the same recipe, from anywhere in the repo
#   just --list server          # that app's recipes on their own
#
# Recipes here are the cross-cutting ones: they fan out over all three.

mod android
mod ios
mod server

# List the modules and the cross-cutting recipes.
default:
    @{{ just_executable() }} --list --unsorted

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
    if command -v uv >/dev/null 2>&1; then
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
    for app in server android ios; do
        echo "==> ${app}"
        '{{ just_executable() }}' "${app}::doctor" || true
        echo
    done
