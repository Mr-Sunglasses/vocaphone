from __future__ import annotations

import json
import os
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

VALID_ENGINES = (
    "auto",
    "handy",
    "whisper.cpp",
    "whisperkit",
    "faster-whisper",
    "moonshine",
    "sherpa-onnx",
    "mlx-audio",
)


@dataclass(slots=True)
class RuntimeConfig:
    """User choices made through the WebUI, persisted across restarts."""

    engine: str = "auto"
    whisper_model: str | None = None
    whisperkit_model: str | None = None
    faster_whisper_model: str | None = None
    moonshine_model: str = "moonshine:en"
    moonshine_language: str = "en"
    sherpa_model: str | None = None
    mlx_audio_model: str | None = None
    compute_device: str = "auto"
    compute_type: str = "auto"
    cpu_threads: int = 0
    pairing_url: str | None = None
    pairing_urls: list[str] = field(default_factory=list)

    @classmethod
    def load(cls, path: Path) -> RuntimeConfig:
        try:
            payload: dict[str, Any] = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return cls()
        engine = payload.get("engine")
        whisper_model = payload.get("whisper_model")
        whisperkit_model = payload.get("whisperkit_model")
        faster_whisper_model = payload.get("faster_whisper_model")
        moonshine_model = payload.get("moonshine_model")
        moonshine_language = payload.get("moonshine_language")
        sherpa_model = payload.get("sherpa_model")
        mlx_audio_model = payload.get("mlx_audio_model")
        compute_device = payload.get("compute_device")
        compute_type = payload.get("compute_type")
        cpu_threads = payload.get("cpu_threads")
        pairing_url = payload.get("pairing_url")
        pairing_urls = payload.get("pairing_urls")
        return cls(
            engine=engine if engine in VALID_ENGINES else "auto",
            whisper_model=whisper_model if isinstance(whisper_model, str) else None,
            whisperkit_model=whisperkit_model if isinstance(whisperkit_model, str) else None,
            faster_whisper_model=(
                faster_whisper_model if isinstance(faster_whisper_model, str) else None
            ),
            moonshine_model=(
                moonshine_model
                if isinstance(moonshine_model, str)
                else (
                    f"moonshine:{moonshine_language}"
                    if isinstance(moonshine_language, str)
                    else "moonshine:en"
                )
            ),
            moonshine_language=(
                moonshine_language if isinstance(moonshine_language, str) else "en"
            ),
            sherpa_model=sherpa_model if isinstance(sherpa_model, str) else None,
            mlx_audio_model=(mlx_audio_model if isinstance(mlx_audio_model, str) else None),
            compute_device=compute_device if compute_device in {"auto", "cpu", "cuda"} else "auto",
            compute_type=(
                compute_type
                if compute_type in {"auto", "int8", "int8_float16", "float16", "float32"}
                else "auto"
            ),
            cpu_threads=(
                cpu_threads if isinstance(cpu_threads, int) and 0 <= cpu_threads <= 256 else 0
            ),
            pairing_url=pairing_url if isinstance(pairing_url, str) else None,
            pairing_urls=(
                [url for url in pairing_urls if isinstance(url, str)]
                if isinstance(pairing_urls, list)
                else []
            ),
        )

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "engine": self.engine,
            "whisper_model": self.whisper_model,
            "whisperkit_model": self.whisperkit_model,
            "faster_whisper_model": self.faster_whisper_model,
            "moonshine_model": self.moonshine_model,
            "moonshine_language": self.moonshine_language,
            "sherpa_model": self.sherpa_model,
            "mlx_audio_model": self.mlx_audio_model,
            "compute_device": self.compute_device,
            "compute_type": self.compute_type,
            "cpu_threads": self.cpu_threads,
            "pairing_url": self.pairing_url,
            "pairing_urls": self.pairing_urls,
        }
        descriptor, temporary_name = tempfile.mkstemp(
            dir=path.parent, prefix=".config-", suffix=".tmp"
        )
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(payload, handle, indent=2)
                handle.write("\n")
            os.replace(temporary_name, path)
        except BaseException:
            Path(temporary_name).unlink(missing_ok=True)
            raise
