from __future__ import annotations

import asyncio
import importlib.util
import os
import time
import wave
from array import array
from pathlib import Path
from typing import Any

from app.catalog import CatalogModel
from app.errors import EngineUnavailableError, TranscriptionProcessError
from app.models.base import EngineHealth, EngineTranscription, TranscriptionOptions

MODEL_METADATA = ".localflow-model.json"


class SherpaOnnxEngine:
    """Persistent CPU recognizer for compact sherpa-onnx model exports."""

    def __init__(
        self,
        model_root: Path | None,
        catalog_model: CatalogModel | None,
        *,
        cpu_threads: int = 0,
    ) -> None:
        self.model_root = model_root
        self.catalog_model = catalog_model
        self.cpu_threads = cpu_threads
        self._recognizer: Any | None = None
        self._load_lock = asyncio.Lock()
        self._inference_lock = asyncio.Lock()

    async def health(self) -> EngineHealth:
        package_ready = importlib.util.find_spec("sherpa_onnx") is not None
        model_ready = (
            self.model_root is not None
            and self.catalog_model is not None
            and (self.model_root / MODEL_METADATA).is_file()
            and all(
                (self.model_root / name).is_file() for name in self.catalog_model.required_files
            )
        )
        model_name = self.model_root.name if self.model_root else "no-model-selected"
        return EngineHealth(
            ready=package_ready and model_ready,
            name=f"sherpa-onnx:{model_name}",
        )

    async def warmup(self) -> int:
        if not (await self.health()).ready:
            return 0
        await self._ensure_recognizer()
        return _directory_size(self.model_root) if self.model_root else 0

    async def transcribe(
        self, audio_path: Path, options: TranscriptionOptions
    ) -> EngineTranscription:
        self._validate_language(options.language)
        if not (await self.health()).ready:
            raise EngineUnavailableError(
                "sherpa-onnx or its selected model is unavailable. Install the engines extra "
                "and download a compatible sherpa-onnx model."
            )
        async with self._inference_lock:
            load_started = time.monotonic()
            recognizer, loaded_now = await self._ensure_recognizer()
            model_load_ms = _elapsed_ms(load_started) if loaded_now else 0
            inference_started = time.monotonic()
            try:
                text = await asyncio.wait_for(
                    asyncio.to_thread(_decode_wave, recognizer, audio_path),
                    timeout=180,
                )
            except TimeoutError as error:
                raise TranscriptionProcessError("sherpa-onnx transcription timed out.") from error
            except Exception as error:
                raise TranscriptionProcessError(
                    f"sherpa-onnx failed: {str(error)[-240:]}"
                ) from error
            if not text:
                raise TranscriptionProcessError("sherpa-onnx returned an empty transcript.")
            return EngineTranscription(
                text=text,
                model_load_ms=model_load_ms,
                inference_ms=_elapsed_ms(inference_started),
            )

    async def _ensure_recognizer(self) -> tuple[Any, bool]:
        if self._recognizer is not None:
            return self._recognizer, False
        async with self._load_lock:
            if self._recognizer is not None:
                return self._recognizer, False
            self._recognizer = await asyncio.to_thread(self._load_recognizer_sync)
            return self._recognizer, True

    def _load_recognizer_sync(self) -> Any:
        if self.model_root is None or self.catalog_model is None:
            raise EngineUnavailableError("No sherpa-onnx model is selected.")
        import sherpa_onnx

        threads = self.cpu_threads or max(1, min(os.cpu_count() or 1, 8))
        tokens = str(self.model_root / "tokens.txt")
        if self.catalog_model.model_type == "sense_voice":
            return sherpa_onnx.OfflineRecognizer.from_sense_voice(
                model=str(self.model_root / "model.int8.onnx"),
                tokens=tokens,
                num_threads=threads,
                language="auto",
                use_itn=True,
                provider="cpu",
            )
        if self.catalog_model.model_type == "nemo_transducer":
            return sherpa_onnx.OfflineRecognizer.from_transducer(
                encoder=str(self.model_root / "encoder.int8.onnx"),
                decoder=str(self.model_root / "decoder.int8.onnx"),
                joiner=str(self.model_root / "joiner.int8.onnx"),
                tokens=tokens,
                num_threads=threads,
                model_type="nemo_transducer",
                provider="cpu",
            )
        raise EngineUnavailableError(
            f"Unsupported sherpa-onnx model type: {self.catalog_model.model_type}."
        )

    def _validate_language(self, language: str) -> None:
        supported = self.catalog_model.language_codes if self.catalog_model else ()
        normalized = _language_code(language)
        if language != "auto" and supported and normalized not in supported:
            choices = ", ".join(supported)
            raise TranscriptionProcessError(
                f"The selected model does not support {language}. Choose Auto, {choices}, or "
                "another model."
            )


def _decode_wave(recognizer: Any, audio_path: Path) -> str:
    with wave.open(str(audio_path), "rb") as source:
        channels = source.getnchannels()
        sample_width = source.getsampwidth()
        sample_rate = source.getframerate()
        frames = source.readframes(source.getnframes())
    if sample_width != 2:
        raise ValueError("sherpa-onnx expects normalized 16-bit PCM WAV audio.")
    samples = array("h")
    samples.frombytes(frames)
    if channels > 1:
        samples = array("h", samples[::channels])
    stream = recognizer.create_stream()
    stream.accept_waveform(sample_rate, [sample / 32768.0 for sample in samples])
    recognizer.decode_stream(stream)
    return str(stream.result.text).strip()


def _language_code(value: str) -> str:
    return value.lower().split("-", maxsplit=1)[0]


def _directory_size(path: Path) -> int:
    return sum(file.stat().st_size for file in path.rglob("*") if file.is_file())


def _elapsed_ms(started: float) -> int:
    return max(0, int((time.monotonic() - started) * 1000))
