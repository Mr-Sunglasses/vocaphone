from __future__ import annotations

import asyncio
import importlib.util
import json
import time
import wave
from array import array
from pathlib import Path
from typing import Any

from app.errors import EngineUnavailableError, TranscriptionProcessError
from app.models.base import EngineHealth, EngineTranscription, TranscriptionOptions

MODEL_METADATA = ".localflow-model.json"


class MoonshineEngine:
    """Persistent Moonshine engine with both batch and incremental APIs."""

    def __init__(self, model_root: Path | None, language: str = "en") -> None:
        self.model_root = model_root
        self.language = language
        self._transcriber: Any | None = None
        self._load_lock = asyncio.Lock()
        self._inference_lock = asyncio.Lock()
        # The package owns mutable decoder state, so batch and streaming jobs
        # must never share the persistent transcriber concurrently.
        self.streaming_lock = self._inference_lock

    async def health(self) -> EngineHealth:
        package_ready = importlib.util.find_spec("moonshine_voice") is not None
        metadata_ready = (
            self.model_root is not None and (self.model_root / MODEL_METADATA).is_file()
        )
        model_name = self.model_root.name if self.model_root else "no-model-selected"
        return EngineHealth(
            ready=package_ready and metadata_ready,
            name=f"moonshine:{model_name}",
        )

    async def warmup(self) -> int:
        if not (await self.health()).ready:
            return 0
        await self._ensure_transcriber()
        return _directory_size(self.model_root) if self.model_root else 0

    async def transcribe(
        self, audio_path: Path, options: TranscriptionOptions
    ) -> EngineTranscription:
        if options.language not in {"auto", "en", "en-US", "en-GB"}:
            raise TranscriptionProcessError(
                "The installed Moonshine model supports English; "
                "choose another engine for this language."
            )
        if not (await self.health()).ready:
            raise EngineUnavailableError(
                "Moonshine or its selected model is unavailable. Install the engines extra and "
                "download the Moonshine English model."
            )
        async with self._inference_lock:
            load_started = time.monotonic()
            transcriber, loaded_now = await self._ensure_transcriber()
            model_load_ms = _elapsed_ms(load_started) if loaded_now else 0
            inference_started = time.monotonic()
            try:
                text = await asyncio.wait_for(
                    asyncio.to_thread(_batch_transcribe, transcriber, audio_path),
                    timeout=120,
                )
            except TimeoutError as error:
                raise TranscriptionProcessError("Moonshine transcription timed out.") from error
            except Exception as error:
                raise TranscriptionProcessError(f"Moonshine failed: {str(error)[-240:]}") from error
            if not text:
                raise TranscriptionProcessError("Moonshine returned an empty transcript.")
            return EngineTranscription(
                text=text,
                model_load_ms=model_load_ms,
                inference_ms=_elapsed_ms(inference_started),
            )

    async def create_stream(self) -> Any:
        transcriber, _ = await self._ensure_transcriber()
        return await asyncio.to_thread(_start_stream, transcriber)

    async def _ensure_transcriber(self) -> tuple[Any, bool]:
        if self._transcriber is not None:
            return self._transcriber, False
        async with self._load_lock:
            if self._transcriber is not None:
                return self._transcriber, False
            self._transcriber = await asyncio.to_thread(self._load_transcriber_sync)
            return self._transcriber, True

    def _load_transcriber_sync(self) -> Any:
        if self.model_root is None:
            raise EngineUnavailableError("No Moonshine model is selected.")
        metadata = json.loads((self.model_root / MODEL_METADATA).read_text(encoding="utf-8"))
        from moonshine_voice import ModelArch, Transcriber  # type: ignore[import-untyped]

        model_path = self.model_root / str(metadata["model_path"])
        return Transcriber(model_path=model_path, model_arch=ModelArch(metadata["model_arch"]))


def _batch_transcribe(transcriber: Any, audio_path: Path) -> str:
    with wave.open(str(audio_path), "rb") as source:
        channels = source.getnchannels()
        sample_width = source.getsampwidth()
        sample_rate = source.getframerate()
        frames = source.readframes(source.getnframes())
    if sample_width != 2:
        raise ValueError("Moonshine expects normalized 16-bit PCM WAV audio.")
    samples = array("h")
    samples.frombytes(frames)
    if channels > 1:
        samples = array("h", samples[::channels])
    floats = [sample / 32768.0 for sample in samples]
    transcript = transcriber.transcribe_without_streaming(floats, sample_rate)
    return " ".join(line.text.strip() for line in transcript.lines if line.text.strip()).strip()


def _start_stream(transcriber: Any) -> Any:
    stream = transcriber.create_stream(update_interval=0.35)
    stream.start()
    return stream


def _directory_size(path: Path) -> int:
    return sum(file.stat().st_size for file in path.rglob("*") if file.is_file())


def _elapsed_ms(started: float) -> int:
    return max(0, int((time.monotonic() - started) * 1000))
