from __future__ import annotations

import asyncio
import math
import os
import wave
from array import array
from pathlib import Path

from app.errors import InvalidAudioError, SilentAudioError

ALLOWED_AUDIO_TYPES = {
    "audio/mp4": ".m4a",
    "audio/m4a": ".m4a",
    "audio/x-m4a": ".m4a",
    "audio/x-caf": ".caf",
    "audio/wav": ".wav",
    "audio/wave": ".wav",
    "audio/webm": ".webm",
    "audio/ogg": ".ogg",
}


class FFmpegNormalizer:
    def __init__(self, ffmpeg_binary: str = "ffmpeg") -> None:
        self.ffmpeg_binary = ffmpeg_binary

    async def normalize(self, source: Path, destination: Path, maximum_seconds: int) -> Path:
        destination.parent.mkdir(parents=True, exist_ok=True)
        process = await asyncio.create_subprocess_exec(
            self.ffmpeg_binary,
            "-nostdin",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(source),
            "-t",
            str(maximum_seconds + 1),
            "-ac",
            "1",
            "-ar",
            "16000",
            "-c:a",
            "pcm_s16le",
            "-y",
            str(destination),
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
        )
        _, stderr = await process.communicate()
        if process.returncode != 0:
            destination.unlink(missing_ok=True)
            raise InvalidAudioError(_safe_ffmpeg_message(stderr))
        try:
            self._validate_wave(destination, maximum_seconds)
        except Exception:
            destination.unlink(missing_ok=True)
            raise
        return destination

    @staticmethod
    def _validate_wave(path: Path, maximum_seconds: int) -> None:
        try:
            with wave.open(str(path), "rb") as recording:
                frames = recording.getnframes()
                rate = recording.getframerate()
                width = recording.getsampwidth()
                if width != 2 or recording.getnchannels() != 1 or rate != 16000:
                    raise InvalidAudioError("Normalized audio has an unexpected format.")
                duration = frames / rate if rate else 0
                if duration <= 0.15:
                    raise InvalidAudioError("Recording is empty or too short.")
                if duration > maximum_seconds + 0.25:
                    raise InvalidAudioError("Recording exceeds the duration limit.")
                samples = array("h", recording.readframes(frames))
        except (wave.Error, EOFError) as error:
            raise InvalidAudioError("Recording could not be decoded.") from error
        if not samples:
            raise InvalidAudioError("Recording contains no audio frames.")
        rms = math.sqrt(sum(sample * sample for sample in samples) / len(samples))
        if rms < 20:
            raise SilentAudioError("Recording appears to be silent.")


def atomic_upload_path(directory: Path, session_id: str, suffix: str) -> tuple[Path, Path]:
    directory.mkdir(parents=True, exist_ok=True)
    final = directory / f"{session_id}{suffix}"
    temporary = directory / f".{session_id}.upload"
    return temporary, final


def complete_atomic_upload(temporary: Path, final: Path) -> None:
    os.replace(temporary, final)


def _safe_ffmpeg_message(stderr: bytes | None) -> str:
    if not stderr:
        return "FFmpeg could not decode the recording."
    last_line = stderr.decode("utf-8", errors="replace").strip().splitlines()[-1]
    return f"FFmpeg rejected the recording: {last_line[:160]}"
