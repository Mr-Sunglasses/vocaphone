from __future__ import annotations

import wave
from pathlib import Path

import pytest

from app.audio import FFmpegNormalizer
from app.errors import InvalidAudioError, SilentAudioError


async def test_ffmpeg_normalizes_real_audio(
    tmp_path: Path,
    audio_bytes: bytes,
) -> None:
    source = tmp_path / "source.wav"
    destination = tmp_path / "normalized.wav"
    source.write_bytes(audio_bytes)
    result = await FFmpegNormalizer().normalize(source, destination, 120)
    with wave.open(str(result), "rb") as normalized:
        assert normalized.getframerate() == 16000
        assert normalized.getnchannels() == 1


async def test_ffmpeg_rejects_invalid_audio(tmp_path: Path) -> None:
    source = tmp_path / "invalid.m4a"
    source.write_bytes(b"not audio" * 100)
    with pytest.raises(InvalidAudioError):
        await FFmpegNormalizer().normalize(source, tmp_path / "output.wav", 120)


async def test_silence_is_rejected(tmp_path: Path) -> None:
    source = tmp_path / "silent.wav"
    with wave.open(str(source), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(16000)
        output.writeframes(b"\0\0" * 8000)
    with pytest.raises(SilentAudioError):
        await FFmpegNormalizer().normalize(source, tmp_path / "output.wav", 120)
