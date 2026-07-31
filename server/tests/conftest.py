from __future__ import annotations

import math
import wave
from array import array
from collections.abc import AsyncIterator
from pathlib import Path

import httpx
import pytest

from app.config import Settings
from app.main import create_app
from app.models.base import EngineHealth, TranscriptionOptions

TOKEN = "test-" + ("x" * 48)


class FakeEngine:
    def __init__(self, transcript: str = "hello from the local model") -> None:
        self.transcript = transcript
        self.calls = 0

    async def health(self) -> EngineHealth:
        return EngineHealth(ready=True, name="fake-local-model")

    async def transcribe(self, audio_path: Path, options: TranscriptionOptions) -> str:
        assert audio_path.is_file()
        self.calls += 1
        return self.transcript


class FakeNormalizer:
    async def normalize(self, source: Path, destination: Path, maximum_seconds: int) -> Path:
        assert source.is_file()
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(b"normalized")
        return destination


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    return Settings(
        token=TOKEN,
        data_dir=tmp_path,
        whisper_binary=tmp_path / "whisper-cli",
        whisper_model=tmp_path / "model.bin",
        maximum_upload_bytes=20_000,
    )


@pytest.fixture
async def client(settings: Settings) -> AsyncIterator[httpx.AsyncClient]:
    app = create_app(settings, engine=FakeEngine(), normalizer=FakeNormalizer())
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app),
        base_url="http://test",
    ) as test_client:
        yield test_client


@pytest.fixture
def authorization() -> dict[str, str]:
    return {"Authorization": f"Bearer {TOKEN}"}


@pytest.fixture
def audio_bytes(tmp_path: Path) -> bytes:
    path = tmp_path / "speech.wav"
    samples = array(
        "h",
        (int(3000 * math.sin(2 * math.pi * 440 * index / 16000)) for index in range(8000)),
    )
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(16000)
        output.writeframes(samples.tobytes())
    return path.read_bytes()
