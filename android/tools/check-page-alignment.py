#!/usr/bin/env python3
"""Fail if an APK carries a 64-bit library that a 16 KB-page device cannot load.

Android's loader refuses to map a shared library whose PT_LOAD segments are
aligned below the running kernel's page size. Devices shipping with Android 15
or newer use 16 KB pages, and Play requires 16 KB support of every app targeting
Android 15+, so a 4 KB-aligned library means `dlopen` fails outright on that
whole device class -- on-device transcription simply unavailable, with nothing
in the app's own log to say why.

This existed as a real regression: every prebuilt library the project ships
already arrived 16 KB aligned and AGP page-aligns the APK's zip entries by
itself, so the only 4 KB segments in a release build came from the libraries
compiled here, and nothing in the build or in lint noticed. The linker flag that
fixes it lives in app/src/main/cpp/whisper/CMakeLists.txt; this is what keeps it
there.

32-bit ABIs are exempt. Their page size has not changed, and NDK r28 leaves
them at 4 KB too.

Usage: check-page-alignment.py <apk-or-aab-or-directory>...
"""

from __future__ import annotations

import struct
import sys
import zipfile
from pathlib import Path

REQUIRED_ALIGNMENT = 16 * 1024
PT_LOAD = 1
ELF_MAGIC = b"\x7fELF"
ELFCLASS64 = 2


def load_segment_alignments(data: bytes) -> list[int] | None:
    """PT_LOAD alignments of a 64-bit ELF, or None if this is not one."""
    if data[:4] != ELF_MAGIC or data[4] != ELFCLASS64:
        return None
    (e_phoff,) = struct.unpack_from("<Q", data, 0x20)
    (e_phentsize,) = struct.unpack_from("<H", data, 0x36)
    (e_phnum,) = struct.unpack_from("<H", data, 0x38)
    alignments = []
    for index in range(e_phnum):
        offset = e_phoff + index * e_phentsize
        (p_type,) = struct.unpack_from("<I", data, offset)
        if p_type == PT_LOAD:
            (p_align,) = struct.unpack_from("<Q", data, offset + 0x30)
            alignments.append(p_align)
    return alignments


def libraries(target: Path):
    """Yields (label, bytes) for every native library in an APK, AAB or directory."""
    if target.is_dir():
        for path in sorted(target.rglob("*.so")):
            yield str(path.relative_to(target)), path.read_bytes()
        return
    with zipfile.ZipFile(target) as archive:
        for entry in sorted(archive.namelist()):
            if entry.endswith(".so"):
                yield entry, archive.read(entry)


def check(target: Path) -> list[str]:
    failures = []
    checked = 0
    for label, data in libraries(target):
        alignments = load_segment_alignments(data)
        # None means a 32-bit library, which is exempt rather than passing.
        if alignments is None:
            continue
        checked += 1
        if any(alignment < REQUIRED_ALIGNMENT for alignment in alignments):
            found = ", ".join(hex(alignment) for alignment in sorted(set(alignments)))
            failures.append(f"{label}: PT_LOAD aligned to {found}, needs 0x4000")
    if checked == 0:
        failures.append(
            f"no 64-bit libraries found in {target} -- "
            "the build output moved, and this check was passing on nothing"
        )
    return failures


def main(argv: list[str]) -> int:
    targets = [Path(argument) for argument in argv[1:]]
    if not targets:
        print(__doc__, file=sys.stderr)
        return 2

    failed = False
    for target in targets:
        if not target.exists():
            print(f"✗ {target}: not found", file=sys.stderr)
            failed = True
            continue
        failures = check(target)
        if failures:
            failed = True
            print(f"✗ {target}", file=sys.stderr)
            for failure in failures:
                print(f"    {failure}", file=sys.stderr)
        else:
            print(f"✓ {target}: every 64-bit library is 16 KB aligned")

    if failed:
        print(
            "\nAdd -Wl,-z,max-page-size=16384 to the link options for the 64-bit "
            "ABIs, or build with NDK r28+, which does it by default.",
            file=sys.stderr,
        )
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
