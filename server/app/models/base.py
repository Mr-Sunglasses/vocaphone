from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Protocol


@dataclass(frozen=True, slots=True)
class EngineHealth:
    ready: bool
    name: str


@dataclass(frozen=True, slots=True)
class TranscriptionOptions:
    language: str
    style: str


class TranscriptionEngine(Protocol):
    async def health(self) -> EngineHealth: ...

    async def transcribe(self, audio_path: Path, options: TranscriptionOptions) -> str: ...


class AudioNormalizer(Protocol):
    async def normalize(self, source: Path, destination: Path, maximum_seconds: int) -> Path: ...
