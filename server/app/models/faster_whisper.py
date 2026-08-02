from __future__ import annotations

import asyncio
import importlib.util
import os
import time
from pathlib import Path
from typing import Any

from app.errors import EngineUnavailableError, TranscriptionProcessError
from app.models.base import EngineHealth, EngineTranscription, TranscriptionOptions


class FasterWhisperEngine:
    """Persistent CTranslate2-backed Whisper engine optimized for server use."""

    def __init__(
        self,
        model_path: Path | None,
        *,
        device: str = "auto",
        compute_type: str = "auto",
        cpu_threads: int = 0,
    ) -> None:
        self.model_path = model_path
        self.device = device
        self.compute_type = compute_type
        self.cpu_threads = cpu_threads
        self._model: Any | None = None
        self._load_lock = asyncio.Lock()
        self._inference_lock = asyncio.Lock()

    async def health(self) -> EngineHealth:
        package_ready = importlib.util.find_spec("faster_whisper") is not None
        model_ready = self.model_path is not None and (self.model_path / "model.bin").is_file()
        model_name = self.model_path.name if self.model_path else "no-model-selected"
        return EngineHealth(
            ready=package_ready and model_ready,
            name=f"faster-whisper:{model_name}",
        )

    async def warmup(self) -> int:
        if not (await self.health()).ready:
            return 0
        await self._ensure_model()
        return _directory_size(self.model_path) if self.model_path else 0

    async def transcribe(
        self, audio_path: Path, options: TranscriptionOptions
    ) -> EngineTranscription:
        if not (await self.health()).ready:
            raise EngineUnavailableError(
                "faster-whisper or its selected model is unavailable. Install the engines "
                "extra and select a downloaded faster-whisper model."
            )
        async with self._inference_lock:
            load_started = time.monotonic()
            model, loaded_now = await self._ensure_model()
            model_load_ms = _elapsed_ms(load_started) if loaded_now else 0
            inference_started = time.monotonic()
            try:
                transcript = await asyncio.wait_for(
                    asyncio.to_thread(self._transcribe_sync, model, audio_path, options),
                    timeout=180,
                )
            except TimeoutError as error:
                raise TranscriptionProcessError(
                    "faster-whisper transcription timed out."
                ) from error
            except Exception as error:
                raise TranscriptionProcessError(
                    f"faster-whisper failed: {str(error)[-240:]}"
                ) from error
            inference_ms = _elapsed_ms(inference_started)
            if not transcript:
                raise TranscriptionProcessError("faster-whisper returned an empty transcript.")
            return EngineTranscription(
                text=transcript,
                model_load_ms=model_load_ms,
                inference_ms=inference_ms,
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
        if self.model_path is None:
            raise EngineUnavailableError("No faster-whisper model is selected.")
        from faster_whisper import WhisperModel

        device = _resolved_device(self.device)
        compute_type = _resolved_compute_type(self.compute_type, device)
        threads = self.cpu_threads or max(1, min(os.cpu_count() or 1, 8))
        return WhisperModel(
            str(self.model_path),
            device=device,
            compute_type=compute_type,
            cpu_threads=threads,
            num_workers=1,
            local_files_only=True,
        )

    @staticmethod
    def _transcribe_sync(model: Any, audio_path: Path, options: TranscriptionOptions) -> str:
        segments, _ = model.transcribe(
            str(audio_path),
            language=None if options.language == "auto" else options.language,
            beam_size=1,
            best_of=1,
            temperature=0,
            condition_on_previous_text=False,
            vad_filter=False,
        )
        return " ".join(
            segment.text.strip() for segment in segments if segment.text.strip()
        ).strip()


def _resolved_device(value: str) -> str:
    if value in {"cpu", "cuda"}:
        return value
    try:
        import ctranslate2

        if ctranslate2.get_cuda_device_count() > 0:
            return "cuda"
    except (ImportError, RuntimeError):
        pass
    return "cpu"


def _resolved_compute_type(value: str, device: str) -> str:
    if value != "auto":
        return value
    return "float16" if device == "cuda" else "int8"


def _elapsed_ms(started: float) -> int:
    return max(0, int((time.monotonic() - started) * 1000))


def _directory_size(path: Path) -> int:
    return sum(file.stat().st_size for file in path.rglob("*") if file.is_file())
