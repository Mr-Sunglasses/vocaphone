#!/usr/bin/env python3
"""Fail if any preview or debug-only symbol is reachable from a release build.

The design standard's implementation guidance is "keep design-preview and debug
states out of release behavior". The preview harness is the largest amount of
debug-only code this app has ever carried, so the rule needs something that
enforces it rather than a convention.

Two checks:

1. Files that exist only for previews must be wrapped in ``#if DEBUG`` from
   their first line of code to their last.
2. No preview-only symbol may be referenced from outside a ``#if DEBUG``
   region, anywhere in the iOS sources.

A Release build would catch the second one too, but only by compiling the whole
app plus WhisperKit — this runs in under a second, so it can sit in CI beside
the tests instead of doubling the macOS minutes.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Sources only. `build/` holds checked-out Swift packages, which are not ours.
SOURCE_DIRS = (
    "VocaPhoneApp",
    "VocaPhoneKeyboard",
    "VocaPhoneLiveActivity",
    "VocaPhoneShared",
    "VocaPhoneActivityShared",
    "VocaPhoneTests",
)

# Files whose entire contents exist for the canvas.
PREVIEW_ONLY_FILES = (
    "VocaPhoneApp/App/Previews/PreviewFixtures.swift",
    "VocaPhoneApp/App/Previews/PreviewMatrix.swift",
    "VocaPhoneApp/App/Previews/DesignSystemPreviews.swift",
    "VocaPhoneKeyboard/KeyboardViewPreview.swift",
)

# Symbols that must never be named outside a DEBUG region. Word-boundary
# matched, so `preview` inside `KeyboardPreview` — a real, shipping view — does
# not trip the check.
DEBUG_ONLY_SYMBOLS = (
    "PreviewFixtures",
    "PreviewHost",
    "PreviewMatrix",
    "PreviewVariant",
    "KeyboardViewPreview",
    "KeyboardPreviewEnvironment",
    "isPreviewFixture",
    "previewIsRecording",
    "previewTranscripts",
    "previewSelectedModelID",
    "previewFilter",
    "previewIdle",
    "previewStandby",
)

SYMBOL_PATTERN = re.compile(r"\b(" + "|".join(DEBUG_ONLY_SYMBOLS) + r")\b")
PREVIEW_MACRO = re.compile(r"#Preview\b")


def swift_files() -> list[Path]:
    files: list[Path] = []
    for directory in SOURCE_DIRS:
        files.extend(sorted((ROOT / directory).rglob("*.swift")))
    return files


def debug_regions(lines: list[str]) -> list[bool]:
    """For each line, whether it compiles only when DEBUG is defined.

    Tracks conditional-compilation nesting rather than matching text, so a
    `#Preview` inside `#if DEBUG` … `#else` counts as release code — which it
    is.
    """
    inside: list[bool] = []
    # One frame per open `#if`: (is this branch DEBUG-only, was any branch so far)
    stack: list[tuple[bool, bool]] = []

    def in_debug() -> bool:
        # A file with no conditionals at all is release code, so an empty stack
        # is False — `all([])` is True, which is exactly the wrong answer here.
        return bool(stack) and all(frame[0] for frame in stack)

    for raw in lines:
        line = raw.strip()
        if line.startswith("#if"):
            is_debug = bool(re.fullmatch(r"#if\s+DEBUG", line))
            stack.append((is_debug, is_debug))
            inside.append(in_debug())
            continue
        if line.startswith("#elseif") or line.startswith("#else"):
            if stack:
                was_debug = re.fullmatch(r"#elseif\s+DEBUG", line) is not None
                stack[-1] = (was_debug, stack[-1][1])
            inside.append(in_debug())
            continue
        if line.startswith("#endif"):
            if stack:
                stack.pop()
            inside.append(in_debug())
            continue
        inside.append(in_debug())
    return inside


def check_wrapped(path: Path, failures: list[str]) -> None:
    lines = path.read_text(encoding="utf-8").splitlines()
    flags = debug_regions(lines)
    for number, (line, is_debug) in enumerate(zip(lines, flags), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("//"):
            continue
        if stripped.startswith("#if") or stripped.startswith("#endif"):
            continue
        if not is_debug:
            failures.append(
                f"{path.relative_to(ROOT)}:{number}: preview-only file has code "
                f"outside `#if DEBUG`"
            )
            return


def check_references(path: Path, failures: list[str]) -> None:
    relative = str(path.relative_to(ROOT))
    if relative in PREVIEW_ONLY_FILES:
        return
    lines = path.read_text(encoding="utf-8").splitlines()
    flags = debug_regions(lines)
    for number, (line, is_debug) in enumerate(zip(lines, flags), start=1):
        if is_debug:
            continue
        stripped = line.strip()
        if stripped.startswith("//") or stripped.startswith("///"):
            continue
        match = SYMBOL_PATTERN.search(line)
        if match:
            failures.append(
                f"{relative}:{number}: `{match.group(1)}` is preview-only and is "
                f"referenced outside `#if DEBUG`"
            )
        if PREVIEW_MACRO.search(line):
            failures.append(
                f"{relative}:{number}: `#Preview` outside `#if DEBUG`"
            )


def main() -> int:
    failures: list[str] = []

    for relative in PREVIEW_ONLY_FILES:
        path = ROOT / relative
        if not path.exists():
            failures.append(f"{relative}: listed as preview-only but does not exist")
            continue
        check_wrapped(path, failures)

    for path in swift_files():
        check_references(path, failures)

    if failures:
        print("Preview code is reachable from a release build:\n", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        print(
            "\nWrap it in `#if DEBUG`, or move it into a preview-only file.",
            file=sys.stderr,
        )
        return 1

    print("Preview isolation: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
