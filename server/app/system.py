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
    logical_cpus: int
    effective_cpus: float
    containerized: bool
    accelerators: tuple[str, ...]
    cpu_features: tuple[str, ...]


def detect_system(
    *,
    whisper_binary: Path,
    whisperkit_binary: str,
    handy_binary: Path,
) -> SystemInfo:
    arch = platform.machine()
    is_mac = platform.system() == "Darwin"
    chip = _sysctl("machdep.cpu.brand_string") if is_mac else _linux_cpu_brand()
    ram_gb = _ram_gb(is_mac)
    logical_cpus = os.cpu_count() or 1
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
        logical_cpus=logical_cpus,
        effective_cpus=_effective_cpu_count(logical_cpus),
        containerized=_is_containerized(),
        accelerators=_accelerators(is_mac, arch),
        cpu_features=_cpu_features(is_mac),
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
    detected_bytes = pages * page_size
    try:
        memory_limit = Path("/sys/fs/cgroup/memory.max").read_text(encoding="utf-8").strip()
        if memory_limit != "max":
            detected_bytes = min(detected_bytes, int(memory_limit))
    except (OSError, ValueError):
        pass
    return round(detected_bytes / (1024**3), 1)


def _linux_cpu_brand() -> str:
    try:
        for line in Path("/proc/cpuinfo").read_text(encoding="utf-8").splitlines():
            if line.lower().startswith(("model name", "hardware")) and ":" in line:
                return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return platform.processor() or platform.machine()


def _effective_cpu_count(logical_cpus: int) -> float:
    limits = [float(logical_cpus)]
    try:
        quota, period = Path("/sys/fs/cgroup/cpu.max").read_text(encoding="utf-8").split()[:2]
        if quota != "max" and int(period) > 0:
            limits.append(max(0.1, int(quota) / int(period)))
    except (OSError, ValueError):
        pass
    for candidate in (
        Path("/sys/fs/cgroup/cpuset.cpus.effective"),
        Path("/sys/fs/cgroup/cpuset/cpuset.cpus"),
    ):
        try:
            count = _count_cpu_set(candidate.read_text(encoding="utf-8").strip())
        except (OSError, ValueError):
            continue
        if count:
            limits.append(float(count))
            break
    return round(min(limits), 2)


def _count_cpu_set(value: str) -> int:
    count = 0
    for part in value.split(","):
        if not part:
            continue
        if "-" in part:
            start, end = part.split("-", 1)
            count += max(0, int(end) - int(start) + 1)
        else:
            int(part)
            count += 1
    return count


def _is_containerized() -> bool:
    if Path("/.dockerenv").exists() or os.environ.get("CONTAINER"):
        return True
    try:
        cgroup = Path("/proc/1/cgroup").read_text(encoding="utf-8").lower()
    except OSError:
        return False
    return any(marker in cgroup for marker in ("docker", "containerd", "kubepods", "podman"))


def _accelerators(is_mac: bool, arch: str) -> tuple[str, ...]:
    values = ["CPU"]
    if is_mac and arch == "arm64":
        values.append("Metal/Core ML")
    if Path("/dev/nvidia0").exists() or shutil.which("nvidia-smi"):
        values.append("NVIDIA CUDA")
    if Path("/dev/kfd").exists():
        values.append("AMD ROCm")
    if Path("/dev/dri/renderD128").exists():
        values.append("Vulkan/VAAPI device")
    return tuple(values)


def _cpu_features(is_mac: bool) -> tuple[str, ...]:
    if is_mac:
        raw = " ".join((_sysctl("machdep.cpu.features"), _sysctl("machdep.cpu.leaf7_features")))
    else:
        try:
            raw = Path("/proc/cpuinfo").read_text(encoding="utf-8")
        except OSError:
            raw = ""
    lowered = set(raw.lower().replace(":", " ").split())
    wanted = ("avx", "avx2", "avx512f", "fma", "neon", "asimd")
    return tuple(feature.upper() for feature in wanted if feature in lowered)
