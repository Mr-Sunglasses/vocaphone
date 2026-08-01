from __future__ import annotations

import mmap
import os
from collections.abc import Iterable
from pathlib import Path

DEFAULT_WARMUP_BYTES = 256 * 1024 * 1024


def prefetch_model_paths(paths: Iterable[Path], maximum_bytes: int = DEFAULT_WARMUP_BYTES) -> int:
    """Ask the OS to prefetch model pages without retaining transcripts or model data."""
    candidates: list[tuple[int, Path]] = []
    for path in paths:
        if path.is_file():
            candidates.append((path.stat().st_size, path))
        elif path.is_dir():
            candidates.extend(
                (candidate.stat().st_size, candidate)
                for candidate in path.rglob("*")
                if candidate.is_file()
            )
    advised = 0
    for size, path in sorted(candidates, key=lambda candidate: candidate[0], reverse=True):
        remaining = maximum_bytes - advised
        if remaining <= 0:
            break
        requested = min(size, remaining)
        if requested <= 0:
            continue
        advised += _prefetch_file(path, requested)
    return advised


def _prefetch_file(path: Path, length: int) -> int:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        posix_fadvise = getattr(os, "posix_fadvise", None)
        will_need = getattr(os, "POSIX_FADV_WILLNEED", None)
        if callable(posix_fadvise) and isinstance(will_need, int):
            posix_fadvise(descriptor, 0, length, will_need)
            return length
        if not hasattr(mmap, "MADV_WILLNEED"):
            return 0
        with mmap.mmap(descriptor, length, access=mmap.ACCESS_READ) as mapped:
            mapped.madvise(mmap.MADV_WILLNEED)
        return length
    except (OSError, ValueError):
        return 0
    finally:
        os.close(descriptor)
