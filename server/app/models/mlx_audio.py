from __future__ import annotations

import asyncio
import importlib.util
import inspect
import platform
import time
from pathlib import Path
from typing import Any

from app.catalog import CatalogModel
from app.errors import (
    EngineUnavailableError,
    LanguageUnsupportedError,
    TranscriptionProcessError,
)
from app.models.base import EngineHealth, EngineTranscription, TranscriptionOptions


class MLXAudioEngine:
    """Persistent Apple-silicon STT engine backed by MLX Audio."""

    def __init__(self, model_root: Path | None, catalog_model: CatalogModel | None) -> None:
        self.model_root = model_root
        self.catalog_model = catalog_model
        self._model: Any | None = None
        self._load_lock = asyncio.Lock()
        self._inference_lock = asyncio.Lock()

    async def health(self) -> EngineHealth:
        package_ready = importlib.util.find_spec("mlx_audio") is not None
        platform_ready = platform.system() == "Darwin" and platform.machine() == "arm64"
        model_ready = (
            self.model_root is not None and (self.model_root / "model.safetensors").is_file()
        )
        model_name = self.model_root.name if self.model_root else "no-model-selected"
        return EngineHealth(
            ready=package_ready and platform_ready and model_ready,
            name=f"mlx-audio:{model_name}",
        )

    async def warmup(self) -> int:
        if not (await self.health()).ready:
            return 0
        await self._ensure_model()
        return _directory_size(self.model_root) if self.model_root else 0

    async def transcribe(
        self, audio_path: Path, options: TranscriptionOptions
    ) -> EngineTranscription:
        self._validate_language(options.language)
        if not (await self.health()).ready:
            raise EngineUnavailableError(
                "MLX Audio requires an Apple-silicon Mac, the apple engine extra, and a "
                "downloaded MLX model."
            )
        async with self._inference_lock:
            load_started = time.monotonic()
            model, loaded_now = await self._ensure_model()
            model_load_ms = _elapsed_ms(load_started) if loaded_now else 0
            inference_started = time.monotonic()
            try:
                text = await asyncio.wait_for(
                    asyncio.to_thread(_generate_text, model, audio_path, options.language),
                    timeout=180,
                )
            except TimeoutError as error:
                raise TranscriptionProcessError("MLX Audio transcription timed out.") from error
            except Exception as error:
                raise TranscriptionProcessError(f"MLX Audio failed: {str(error)[-240:]}") from error
            if not text:
                raise TranscriptionProcessError("MLX Audio returned an empty transcript.")
            return EngineTranscription(
                text=text,
                model_load_ms=model_load_ms,
                inference_ms=_elapsed_ms(inference_started),
            )

    async def _ensure_model(self) -> tuple[Any, bool]:
        if self._model is not None:
            return self._model, False
        async with self._load_lock:
            if self._model is not None:
                return self._model, False
            self._model = await asyncio.to_thread(self._load_model_sync)
            return self._model, True

    def _load_model_sync(self) -> Any:
        if self.model_root is None:
            raise EngineUnavailableError("No MLX Audio model is selected.")
        from mlx_audio.stt.utils import load

        return load(self.model_root)

    def _validate_language(self, language: str) -> None:
        supported = self.catalog_model.language_codes if self.catalog_model else ()
        normalized = _language_code(language)
        if language != "auto" and supported and normalized not in supported:
            choices = ", ".join(supported)
            raise LanguageUnsupportedError(
                f"The selected MLX model does not support {language}. Choose Auto, {choices}, "
                "or another model."
            )


def _generate_text(model: Any, audio_path: Path, language: str) -> str:
    parameters = inspect.signature(model.generate).parameters
    arguments: dict[str, Any] = {}
    if language != "auto" and "language" in parameters:
        arguments["language"] = _language_code(language)
    result = model.generate(str(audio_path), **arguments)
    return str(result.text).strip()


def _language_code(value: str) -> str:
    return value.lower().split("-", maxsplit=1)[0]


def _directory_size(path: Path) -> int:
    return sum(file.stat().st_size for file in path.rglob("*") if file.is_file())


def _elapsed_ms(started: float) -> int:
    return max(0, int((time.monotonic() - started) * 1000))
