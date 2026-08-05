from __future__ import annotations

from pathlib import Path

from pytest import MonkeyPatch

from app.models import whisperkit
from app.models.base import EngineTranscription, TranscriptionOptions
from app.models.whisperkit import WhisperKitEngine


class FakeProcess:
    def __init__(self) -> None:
        self.return_code: int | None = None
        self.terminated = False

    def poll(self) -> int | None:
        return self.return_code

    def terminate(self) -> None:
        self.terminated = True
        self.return_code = 0

    def wait(self, timeout: int) -> int:
        assert timeout == 3
        return self.return_code or 0

    def kill(self) -> None:
        self.return_code = -9


async def test_whisperkit_keeps_one_native_server_loaded(
    tmp_path: Path, monkeypatch: MonkeyPatch
) -> None:
    model_path = tmp_path / "openai_whisper-small"
    model_path.mkdir()
    (model_path / "config.json").write_text("{}")
    audio_path = tmp_path / "audio.wav"
    audio_path.write_bytes(b"audio")
    process = FakeProcess()
    starts = 0

    def start_server(_: str, __: Path, ___: Path | None = None) -> whisperkit._WhisperKitServer:
        nonlocal starts
        starts += 1
        return whisperkit._WhisperKitServer(process=process, port=50123)  # type: ignore[arg-type]

    def transcribe(
        _: whisperkit._WhisperKitServer,
        __: Path,
        ___: Path,
        ____: str,
    ) -> str:
        return "persistent native result"

    engine = WhisperKitEngine("whisperkit-cli", model_path)
    monkeypatch.setattr(engine, "_resolved_binary", lambda: "/fake/whisperkit-cli")
    monkeypatch.setattr(whisperkit, "_start_server", start_server)
    monkeypatch.setattr(whisperkit, "_server_transcription", transcribe)

    first = await engine.transcribe(audio_path, TranscriptionOptions("en", "raw"))
    second = await engine.transcribe(audio_path, TranscriptionOptions("en", "raw"))

    assert isinstance(first, EngineTranscription)
    assert first.text == "persistent native result"
    assert second.model_load_ms == 0
    assert starts == 1

    engine.close()
    assert process.terminated is True


def test_whisperkit_multipart_contains_model_language_and_audio(tmp_path: Path) -> None:
    audio_path = tmp_path / "sample.wav"
    audio_path.write_bytes(b"wave-bytes")

    body = whisperkit._multipart_body(
        "boundary",
        [("model", "whisper-small"), ("language", "en")],
        audio_path,
    )

    assert b'name="model"\r\n\r\nwhisper-small' in body
    assert b'name="language"\r\n\r\nen' in body
    assert b'name="file"; filename="sample.wav"' in body
    assert b"wave-bytes" in body
    assert body.endswith(b"--boundary--\r\n")
