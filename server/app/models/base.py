from __future__ import annotations

import asyncio
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol, runtime_checkable


@dataclass(frozen=True, slots=True)
class EngineHealth:
    ready: bool
    name: str


@dataclass(frozen=True, slots=True)
class TranscriptionOptions:
    language: str
    style: str


@dataclass(frozen=True, slots=True)
class EngineTranscription:
    text: str
    model_load_ms: int = 0
    inference_ms: int = 0


class TranscriptionEngine(Protocol):
    async def health(self) -> EngineHealth: ...

    async def transcribe(
        self, audio_path: Path, options: TranscriptionOptions
    ) -> str | EngineTranscription: ...


class AudioNormalizer(Protocol):
    async def normalize(self, source: Path, destination: Path, maximum_seconds: int) -> Path: ...


@runtime_checkable
class StreamingEngine(Protocol):
    """A `TranscriptionEngine` that can also decode incrementally.

    `supports_streaming` still needs checking even when `isinstance` matches:
    an engine can implement this interface while its *currently selected*
    model doesn't stream (e.g. Moonshine with a batch-only language). See the
    `/v1/stream` WebSocket handler in `main.py`, which is the only caller —
    `create_stream()` must return an object exposing `add_listener(callback)`,
    `add_audio(samples, sample_rate)`, and `stop()`.
    """

    supports_streaming: bool
    streaming_lock: asyncio.Lock

    async def health(self) -> EngineHealth: ...

    async def create_stream(self) -> Any: ...
