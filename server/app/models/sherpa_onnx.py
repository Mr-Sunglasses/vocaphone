from __future__ import annotations

import asyncio
import importlib.util
import os
import time
import wave
from array import array
from collections.abc import Callable
from pathlib import Path
from typing import Any

from app.catalog import CatalogModel
from app.errors import (
    EngineUnavailableError,
    LanguageUnsupportedError,
    TranscriptionProcessError,
)
from app.models.base import EngineHealth, EngineTranscription, TranscriptionOptions

MODEL_METADATA = ".vocaphone-model.json"
STREAMING_MODEL_TYPE = "streaming_zipformer"


class SherpaOnnxEngine:
    """Persistent CPU recognizer for compact sherpa-onnx model exports.

    Most catalog entries are offline (batch) models. One model type,
    `streaming_zipformer`, is different: it loads an `OnlineRecognizer` and
    exposes `create_stream()`/`supports_streaming`/`streaming_lock`, the same
    surface `MoonshineEngine` already provides, so the `/v1/stream` WebSocket
    handler in `main.py` works with either engine without engine-specific code.
    """

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
        # The package owns mutable decoder state, so batch and streaming jobs
        # must never share the persistent recognizer concurrently.
        self.streaming_lock = self._inference_lock

    @property
    def supports_streaming(self) -> bool:
        if self.catalog_model is None:
            return False
        return self.catalog_model.model_type == STREAMING_MODEL_TYPE

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

    async def create_stream(self) -> _SherpaOnnxStreamAdapter:
        if not self.supports_streaming:
            raise EngineUnavailableError("The selected sherpa-onnx model does not stream.")
        if not (await self.health()).ready:
            raise EngineUnavailableError(
                "sherpa-onnx or its selected streaming model is unavailable."
            )
        recognizer, _ = await self._ensure_recognizer()
        stream = await asyncio.to_thread(recognizer.create_stream)
        return _SherpaOnnxStreamAdapter(recognizer, stream)

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
            decode = _decode_wave_online if self.supports_streaming else _decode_wave
            try:
                text = await asyncio.wait_for(
                    asyncio.to_thread(decode, recognizer, audio_path),
                    timeout=180,
                )
            except TimeoutError as error:
                raise TranscriptionProcessError("sherpa-onnx transcription timed out.") from error
            except Exception as error:
                raise TranscriptionProcessError(
                    f"sherpa-onnx failed: {str(error)[-240:]}"
                ) from error
            if not text:
                # A model asked for a language it was never trained on returns
                # nothing at all rather than failing: Dolphin does this for
                # English. Silence was already rejected upstream, so an empty
                # result here means the model could not read this speech.
                if options.language != "auto":
                    raise LanguageUnsupportedError(
                        f"The selected model returned nothing for {options.language}. "
                        "It probably does not cover that language — choose another "
                        "model, or set the language to Automatic."
                    )
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
            # Ordered (encoder, decoder, joiner, tokens) in the catalog entry: not every
            # nemo_transducer export quantizes all three the same way GigaAM's decoder
            # and joiner ship unquantized alongside an INT8 encoder, unlike Parakeet.
            encoder_file, decoder_file, joiner_file, _ = self.catalog_model.required_files
            return sherpa_onnx.OfflineRecognizer.from_transducer(
                encoder=str(self.model_root / encoder_file),
                decoder=str(self.model_root / decoder_file),
                joiner=str(self.model_root / joiner_file),
                tokens=tokens,
                num_threads=threads,
                model_type="nemo_transducer",
                provider="cpu",
            )
        if self.catalog_model.model_type == "nemo_ctc":
            return sherpa_onnx.OfflineRecognizer.from_nemo_ctc(
                model=str(self.model_root / "model.int8.onnx"),
                tokens=tokens,
                num_threads=threads,
                provider="cpu",
            )
        if self.catalog_model.model_type == "nemo_canary":
            # English-only for now: source/target language is fixed at load time, not
            # per request, and the catalog currently only ships an English entry.
            return sherpa_onnx.OfflineRecognizer.from_nemo_canary(
                encoder=str(self.model_root / "encoder.int8.onnx"),
                decoder=str(self.model_root / "decoder.int8.onnx"),
                tokens=tokens,
                num_threads=threads,
                provider="cpu",
            )
        if self.catalog_model.model_type == "dolphin_ctc":
            return sherpa_onnx.OfflineRecognizer.from_dolphin_ctc(
                model=str(self.model_root / "model.int8.onnx"),
                tokens=tokens,
                num_threads=threads,
                provider="cpu",
            )
        if self.catalog_model.model_type == "qwen3_asr":
            # Unlike every other type here, this one takes a Hugging Face tokenizer
            # directory rather than a `tokens.txt`, so it ignores `tokens` entirely.
            return sherpa_onnx.OfflineRecognizer.from_qwen3_asr(
                conv_frontend=str(self.model_root / "conv_frontend.onnx"),
                encoder=str(self.model_root / "encoder.int8.onnx"),
                decoder=str(self.model_root / "decoder.int8.onnx"),
                tokenizer=str(self.model_root / "tokenizer"),
                num_threads=threads,
                provider="cpu",
            )
        if self.catalog_model.model_type == STREAMING_MODEL_TYPE:
            encoder_file, decoder_file, joiner_file, _ = self.catalog_model.required_files
            return sherpa_onnx.OnlineRecognizer.from_transducer(
                tokens=tokens,
                encoder=str(self.model_root / encoder_file),
                decoder=str(self.model_root / decoder_file),
                joiner=str(self.model_root / joiner_file),
                num_threads=threads,
                provider="cpu",
                enable_endpoint_detection=True,
            )
        raise EngineUnavailableError(
            f"Unsupported sherpa-onnx model type: {self.catalog_model.model_type}."
        )

    def _validate_language(self, language: str) -> None:
        supported = self.catalog_model.language_codes if self.catalog_model else ()
        normalized = _language_code(language)
        if language != "auto" and supported and normalized not in supported:
            choices = ", ".join(supported)
            raise LanguageUnsupportedError(
                f"The selected model does not support {language}. Choose Auto, {choices}, or "
                "another model."
            )


def _read_wave_samples(audio_path: Path) -> tuple[int, list[float]]:
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
    return sample_rate, [sample / 32768.0 for sample in samples]


def _decode_wave(recognizer: Any, audio_path: Path) -> str:
    sample_rate, floats = _read_wave_samples(audio_path)
    stream = recognizer.create_stream()
    stream.accept_waveform(sample_rate, floats)
    recognizer.decode_stream(stream)
    return str(stream.result.text).strip()


def _decode_wave_online(recognizer: Any, audio_path: Path) -> str:
    """Batch fallback for a streaming-only model: feed the whole recording as
    one continuous stream and read the final result off the recognizer,
    rather than the stream itself (`OnlineStream` has no `.result`)."""
    sample_rate, floats = _read_wave_samples(audio_path)
    stream = recognizer.create_stream()
    stream.accept_waveform(sample_rate, floats)
    stream.input_finished()
    while recognizer.is_ready(stream):
        recognizer.decode_stream(stream)
    return str(recognizer.get_result(stream)).strip()


class _StreamLine:
    def __init__(self, line_id: int, text: str) -> None:
        self.line_id = line_id
        self.text = text


class _StreamEvent:
    def __init__(self, line: _StreamLine | None) -> None:
        self.line = line


class _StopResult:
    def __init__(self, lines: list[_StreamLine]) -> None:
        self.lines = lines


class _SherpaOnnxStreamAdapter:
    """Adapts sherpa-onnx's `OnlineRecognizer`/`OnlineStream` to the
    `add_listener`/`add_audio`/`stop` interface the `/v1/stream` WebSocket
    handler already uses for Moonshine.

    sherpa-onnx separates the persistent recognizer (the loaded model) from a
    per-connection stream (decode state); the recognizer, not the stream,
    drives decoding (`is_ready`/`decode_stream`) and reports results
    (`get_result`/`is_endpoint`/`reset`). Each completed segment (an
    endpoint) becomes one "line", numbered like Moonshine's, so multiple
    segments across a long dictation join the same way.
    """

    def __init__(self, recognizer: Any, stream: Any) -> None:
        self._recognizer = recognizer
        self._stream = stream
        self._listener: Callable[[object], None] | None = None
        self._completed_lines: list[_StreamLine] = []
        self._next_line_id = 0
        self._last_partial = ""

    def add_listener(self, listener: Callable[[object], None]) -> None:
        self._listener = listener

    def add_audio(self, samples: list[float], sample_rate: int) -> None:
        self._stream.accept_waveform(sample_rate, samples)
        self._drain()

    def stop(self) -> _StopResult:
        self._stream.input_finished()
        self._drain()
        trailing = str(self._recognizer.get_result(self._stream)).strip()
        if trailing:
            self._completed_lines.append(_StreamLine(self._next_line_id, trailing))
        return _StopResult(list(self._completed_lines))

    def _drain(self) -> None:
        while self._recognizer.is_ready(self._stream):
            self._recognizer.decode_stream(self._stream)
        if self._recognizer.is_endpoint(self._stream):
            text = str(self._recognizer.get_result(self._stream)).strip()
            if text:
                line = _StreamLine(self._next_line_id, text)
                self._completed_lines.append(line)
                self._notify(line)
            self._next_line_id += 1
            self._last_partial = ""
            self._recognizer.reset(self._stream)
            return
        partial = str(self._recognizer.get_result(self._stream)).strip()
        if partial and partial != self._last_partial:
            self._last_partial = partial
            self._notify(_StreamLine(self._next_line_id, partial))

    def _notify(self, line: _StreamLine) -> None:
        if self._listener is not None:
            self._listener(_StreamEvent(line))


def _language_code(value: str) -> str:
    return value.lower().split("-", maxsplit=1)[0]


def _directory_size(path: Path) -> int:
    return sum(file.stat().st_size for file in path.rglob("*") if file.is_file())


def _elapsed_ms(started: float) -> int:
    return max(0, int((time.monotonic() - started) * 1000))
