from __future__ import annotations

import os
import platform
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True, slots=True)
class SystemInfo:
    os_name: str
    os_version: str
    arch: str
    chip: str
    ram_gb: float
    is_apple_silicon: bool
    ffmpeg_path: str | None
    whisper_cpp_path: str | None
    whisperkit_cli_path: str | None
    handy_installed: bool


def detect_system(
    *,
    whisper_binary: Path,
    whisperkit_binary: str,
    handy_binary: Path,
) -> SystemInfo:
    arch = platform.machine()
    is_mac = platform.system() == "Darwin"
    chip = _sysctl("machdep.cpu.brand_string") if is_mac else platform.processor()
    ram_gb = _ram_gb(is_mac)
    return SystemInfo(
        os_name=platform.system(),
        os_version=platform.release(),
        arch=arch,
        chip=chip or arch,
        ram_gb=ram_gb,
        is_apple_silicon=is_mac and arch == "arm64",
        ffmpeg_path=shutil.which("ffmpeg"),
        whisper_cpp_path=(
            str(whisper_binary) if whisper_binary.is_file() else shutil.which("whisper-cli")
        ),
        whisperkit_cli_path=_resolve_binary(whisperkit_binary),
        handy_installed=handy_binary.is_file(),
    )


def _resolve_binary(binary: str) -> str | None:
    candidate = Path(binary).expanduser()
    if candidate.is_file():
        return str(candidate)
    return shutil.which(binary)


def _sysctl(key: str) -> str:
    try:
        result = subprocess.run(
            ["sysctl", "-n", key],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""


def _ram_gb(is_mac: bool) -> float:
    if is_mac:
        raw = _sysctl("hw.memsize")
        return round(int(raw) / (1024**3), 1) if raw.isdigit() else 0.0
    try:
        pages = os.sysconf("SC_PHYS_PAGES")
        page_size = os.sysconf("SC_PAGE_SIZE")
    except (OSError, ValueError):
        return 0.0
    if not isinstance(pages, int) or not isinstance(page_size, int):
        return 0.0
    return round((pages * page_size) / (1024**3), 1)
