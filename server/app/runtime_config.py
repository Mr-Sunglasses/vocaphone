from __future__ import annotations

import json
import os
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

VALID_ENGINES = ("auto", "handy", "whisper.cpp", "whisperkit")


@dataclass(slots=True)
class RuntimeConfig:
    """User choices made through the WebUI, persisted across restarts."""

    engine: str = "auto"
    whisper_model: str | None = None
    whisperkit_model: str | None = None

    @classmethod
    def load(cls, path: Path) -> RuntimeConfig:
        try:
            payload: dict[str, Any] = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return cls()
        engine = payload.get("engine")
        whisper_model = payload.get("whisper_model")
        whisperkit_model = payload.get("whisperkit_model")
        return cls(
            engine=engine if engine in VALID_ENGINES else "auto",
            whisper_model=whisper_model if isinstance(whisper_model, str) else None,
            whisperkit_model=whisperkit_model if isinstance(whisperkit_model, str) else None,
        )

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "engine": self.engine,
            "whisper_model": self.whisper_model,
            "whisperkit_model": self.whisperkit_model,
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
