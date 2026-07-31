from __future__ import annotations

import asyncio
import re
from pathlib import Path
from uuid import UUID

from app.config import Settings
from app.errors import (
    APIProblem,
    EngineUnavailableError,
    InvalidAudioError,
    SilentAudioError,
    TranscriptionProcessError,
)
from app.models.base import AudioNormalizer, TranscriptionEngine, TranscriptionOptions
from app.storage import SessionRepository, StoredSession


class TranscriptionService:
    def __init__(
        self,
        settings: Settings,
        repository: SessionRepository,
        engine: TranscriptionEngine,
        normalizer: AudioNormalizer,
    ) -> None:
        self.settings = settings
        self.repository = repository
        self.engine = engine
        self.normalizer = normalizer
        self.upload_dir = settings.data_dir / "audio"
        self.normalized_dir = settings.data_dir / "normalized"
        self._transcription_slots = asyncio.Semaphore(settings.maximum_concurrent_transcriptions)

    async def finish(self, session_id: UUID) -> StoredSession:
        stored = self.require(session_id)
        if stored.state == "completed":
            return stored
        if stored.audio_name is None:
            raise APIProblem(409, "audio_missing", "Upload audio before finishing the session.")
        if stored.state == "transcribing":
            raise APIProblem(
                409,
                "transcription_in_progress",
                "Transcription is already in progress.",
            )

        try:
            await asyncio.wait_for(self._transcription_slots.acquire(), timeout=0.05)
        except TimeoutError as error:
            raise APIProblem(
                503,
                "engine_overloaded",
                "The local transcription engine is busy.",
                recoverable=True,
            ) from error

        source = self._safe_audio_path(stored.audio_name)
        normalized = self.normalized_dir / f"{session_id}.wav"
        try:
            self.repository.update(session_id, state="transcribing")
            await self.normalizer.normalize(
                source, normalized, self.settings.maximum_duration_seconds
            )
            raw = await self.engine.transcribe(
                normalized,
                TranscriptionOptions(language=stored.language, style=stored.style),
            )
            transcript = conservative_cleanup(raw) if stored.style == "clean" else raw.strip()
            completed = self.repository.update(
                session_id,
                state="completed",
                transcript=transcript,
                error_code=None,
                audio_name=None if self.settings.delete_successful_audio else stored.audio_name,
                preserve_audio_name=not self.settings.delete_successful_audio,
            )
            if self.settings.delete_successful_audio:
                source.unlink(missing_ok=True)
            return completed
        except SilentAudioError as error:
            self.repository.update(session_id, state="failed", error_code="silent_audio")
            raise APIProblem(422, "silent_audio", str(error)) from error
        except InvalidAudioError as error:
            self.repository.update(session_id, state="failed", error_code="invalid_audio")
            raise APIProblem(422, "invalid_audio", str(error)) from error
        except EngineUnavailableError as error:
            self.repository.update(session_id, state="failed", error_code="engine_unavailable")
            raise APIProblem(503, "engine_unavailable", str(error), recoverable=True) from error
        except TranscriptionProcessError as error:
            self.repository.update(session_id, state="failed", error_code="transcription_failed")
            raise APIProblem(502, "transcription_failed", str(error), recoverable=True) from error
        finally:
            normalized.unlink(missing_ok=True)
            self._transcription_slots.release()

    def require(self, session_id: UUID) -> StoredSession:
        session = self.repository.get(session_id)
        if session is None:
            raise APIProblem(404, "session_not_found", "The session does not exist.")
        return session

    def delete(self, session_id: UUID) -> bool:
        session = self.repository.delete(session_id)
        if session is None:
            return False
        if session.audio_name:
            self._safe_audio_path(session.audio_name).unlink(missing_ok=True)
        (self.normalized_dir / f"{session_id}.wav").unlink(missing_ok=True)
        return True

    def cleanup_expired(self) -> int:
        expired = self.repository.expired(self.settings.retention_hours)
        for session in expired:
            self.delete(session.session_id)
        return len(expired)

    def _safe_audio_path(self, audio_name: str) -> Path:
        if Path(audio_name).name != audio_name:
            raise APIProblem(500, "invalid_storage_reference", "Stored audio reference is invalid.")
        return self.upload_dir / audio_name


def conservative_cleanup(text: str) -> str:
    result = re.sub(r"[ \t]+", " ", text).strip()
    result = re.sub(r"\s+([,.;:!?])", r"\1", result)
    if result and result[-1] not in ".!?":
        result += "."
    return result
