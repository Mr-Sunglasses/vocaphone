from __future__ import annotations

from array import array
from pathlib import Path
from types import SimpleNamespace

from fastapi.testclient import TestClient
from pytest import MonkeyPatch

from app.config import Settings
from app.main import create_app
from app.models.base import EngineHealth, TranscriptionOptions
from app.models.moonshine import MoonshineEngine

TOKEN = "stream-" + ("x" * 48)


class BatchOnlyEngine:
    async def health(self) -> EngineHealth:
        return EngineHealth(ready=True, name="whisperkit:test-model")

    async def transcribe(self, audio_path: Path, options: TranscriptionOptions) -> str:
        return "batch result"


class FakeStream:
    def __init__(self) -> None:
        self.listener: object | None = None
        self.closed = False

    def add_listener(self, listener: object) -> None:
        self.listener = listener

    def add_audio(self, samples: list[float], sample_rate: int) -> None:
        assert samples
        assert sample_rate == 16_000
        line = SimpleNamespace(text="hello", line_id=1)
        assert callable(self.listener)
        self.listener(SimpleNamespace(line=line))

    def stop(self) -> object:
        return SimpleNamespace(lines=[SimpleNamespace(text="hello world", line_id=1)])

    def close(self) -> None:
        self.closed = True


def test_authenticated_moonshine_stream_returns_styled_transcript(
    tmp_path: Path, monkeypatch: MonkeyPatch
) -> None:
    settings = Settings(
        token=TOKEN,
        data_dir=tmp_path,
        whisper_binary=tmp_path / "whisper-cli",
        whisper_model=tmp_path / "model.bin",
    )
    engine = MoonshineEngine(None)
    stream = FakeStream()

    async def create_stream() -> FakeStream:
        return stream

    async def health() -> EngineHealth:
        return EngineHealth(ready=True, name="moonshine:en")

    monkeypatch.setattr(engine, "create_stream", create_stream)
    monkeypatch.setattr(engine, "health", health)
    app = create_app(settings, engine=engine)

    with (
        TestClient(app) as client,
        client.websocket_connect(
            "/v1/stream", headers={"Authorization": f"Bearer {TOKEN}"}
        ) as websocket,
    ):
        websocket.send_json({"type": "start", "sample_rate": 16_000, "style": "formal"})
        assert websocket.receive_json() == {"type": "ready", "engine": "moonshine"}
        websocket.send_bytes(array("f", [0.1, -0.1]).tobytes())
        assert websocket.receive_json() == {"type": "partial", "transcript": "hello"}
        websocket.send_json({"type": "finish"})
        assert websocket.receive_json() == {
            "type": "complete",
            "transcript": "Hello world.",
        }

    assert stream.closed is True


def test_health_advertises_ready_moonshine_streaming(
    tmp_path: Path, monkeypatch: MonkeyPatch
) -> None:
    settings = Settings(
        token=TOKEN,
        data_dir=tmp_path,
        whisper_binary=tmp_path / "whisper-cli",
        whisper_model=tmp_path / "model.bin",
    )
    engine = MoonshineEngine(None)

    async def health() -> EngineHealth:
        return EngineHealth(ready=True, name="moonshine:en")

    monkeypatch.setattr(engine, "health", health)
    app = create_app(settings, engine=engine)

    with TestClient(app) as client:
        response = client.get("/health")

    assert response.json()["streaming_supported"] is True


def test_authenticated_batch_engine_gets_structured_stream_fallback(tmp_path: Path) -> None:
    settings = Settings(
        token=TOKEN,
        data_dir=tmp_path,
        whisper_binary=tmp_path / "whisper-cli",
        whisper_model=tmp_path / "model.bin",
    )
    app = create_app(settings, engine=BatchOnlyEngine())

    with (
        TestClient(app) as client,
        client.websocket_connect(
            "/v1/stream", headers={"Authorization": f"Bearer {TOKEN}"}
        ) as websocket,
    ):
        assert websocket.receive_json() == {
            "type": "unsupported",
            "reason": "active_engine",
            "engine": "whisperkit:test-model",
        }
