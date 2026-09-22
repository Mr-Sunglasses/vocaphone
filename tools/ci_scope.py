#!/usr/bin/env python3
"""Select PR checks and reject unexpected skips in the required CI gate."""

import json
import os
import subprocess
import sys

CHECKS = ("android", "ios", "web", "assets", "workflows", "codeql", "semgrep")


def select(paths):
    selected = dict.fromkeys(CHECKS, False)
    selected["semgrep"] = True
    for path in paths:
        if path in (".github/workflows/ci.yml", "tools/ci_scope.py",
                    "tools/test_ci_scope.py", "justfile", ".gitmodules"):
            return dict.fromkeys(CHECKS, True)
        for platform in ("android", "ios", "web"):
            if (path.startswith(platform + "/") and not path.endswith(".md")) or (
                path == f".github/workflows/quality-{platform}.yml"
            ) or path.startswith(".github/actions/report-size/"):
                selected[platform] = True
        if path.startswith(".github/actions/setup-android/"):
            selected["android"] = True
        if path in ("tools/android-sbom.init.gradle", "tools/complete_android_sbom.py",
                    "tools/native-dependencies.json", ".github/workflows/android-release.yml"):
            selected["android"] = True
        if path.startswith("assets/keyboard/"):
            selected.update(android=True, ios=True, assets=True)
        if path.startswith(("assets/", "tools/")) or path == ".github/workflows/quality-assets.yml":
            selected["assets"] = True
        if path.startswith((".github/", "tools/")):
            selected["workflows"] = True
        if (path.startswith("web/") and not path.endswith(".md")) or (
            path == ".github/workflows/codeql-web.yml"
        ):
            selected["codeql"] = True
    return selected


def failures(needs, draft=False):
    errors = []
    if draft:
        errors.append("Draft PRs must be marked ready for review.")
    if needs.get("scope", {}).get("result") != "success":
        return errors + ["Scope detection failed."]
    for check in CHECKS:
        wanted = needs["scope"]["outputs"].get(check)
        if wanted not in ("true", "false"):
            errors.append(f"{check}: missing scope decision")
            continue
        expected = "success" if wanted == "true" else "skipped"
        actual = needs.get(check, {}).get("result")
        if actual != expected:
            errors.append(f"{check}: expected {expected}, got {actual}")
    return errors


if __name__ == "__main__":
    if sys.argv[1] == "select":
        # No rename collapsing: both removed and added paths affect scope.
        changed = subprocess.check_output([
            "git", "diff", "--no-renames", "--name-only", "-z",
            f"{os.environ['BASE_SHA']}...{os.environ['HEAD_SHA']}",
        ]).decode().split("\0")
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            for name, enabled in select(changed).items():
                print(f"{name}={str(enabled).lower()}", file=output)
    elif sys.argv[1] == "gate":
        errors = failures(json.loads(os.environ["NEEDS"]), os.environ["DRAFT"] == "true")
        for error in errors:
            print(error, file=sys.stderr)
        sys.exit(bool(errors))
    else:
        sys.exit("Expected select or gate")
