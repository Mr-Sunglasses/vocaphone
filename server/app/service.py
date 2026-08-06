from __future__ import annotations

import asyncio
import platform
import resource
import time
import wave
from dataclasses import dataclass
from pathlib import Path
from uuid import UUID, uuid4

from app.config import Settings
from app.engines import EngineProvider
from app.errors import (
    APIProblem,
    EngineUnavailableError,
    InvalidAudioError,
    LanguageUnsupportedError,
    SilentAudioError,
    TranscriptionProcessError,
)
from app.metrics import PipelineTiming, RuntimeMetrics
from app.models.base import AudioNormalizer, EngineTranscription, TranscriptionOptions
from app.storage import SessionRepository, StoredSession
from app.text_styles import apply_writing_style


class TranscriptionService:
    def __init__(
        self,
        settings: Settings,
        repository: SessionRepository,
        engine_provider: EngineProvider,
        normalizer: AudioNormalizer,
    ) -> None:
        self.settings = settings
        self.repository = repository
        self.engine_provider = engine_provider
        self.normalizer = normalizer
        self.upload_dir = settings.data_dir / "audio"
        self.normalized_dir = settings.data_dir / "normalized"
        self._transcription_slots = asyncio.Semaphore(settings.maximum_concurrent_transcriptions)
        self.metrics = RuntimeMetrics(settings.maximum_concurrent_transcriptions)

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

        source = self._safe_audio_path(stored.audio_name)
        await self._acquire_transcription_slot()

        normalized = self.normalized_dir / f"{session_id}.wav"
        started = time.monotonic()
        normalization_ms = 0
        try:
            self.repository.update(session_id, state="transcribing")
            normalization_started = time.monotonic()
            await self.normalizer.normalize(
                source, normalized, self.settings.maximum_duration_seconds
            )
            normalization_ms = _elapsed_ms(normalization_started)
            audio_duration_ms = _wav_duration_ms(normalized)
            engine = self.engine_provider.current()
            inference_started = time.monotonic()
            raw_result = await engine.transcribe(
                normalized,
                TranscriptionOptions(language=stored.language, style=stored.style),
            )
            outcome = _engine_outcome(raw_result, inference_started)
            raw = outcome.text
            transcript = apply_writing_style(raw, stored.style, stored.language)
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
            total_ms = _elapsed_ms(started)
            engine_name = (await engine.health()).name
            self.metrics.succeeded(
                total_ms,
                _pipeline_timing(
                    total_ms,
                    normalization_ms,
                    outcome,
                    audio_duration_ms,
                    engine_name,
                ),
            )
            return completed
        except SilentAudioError as error:
            self.metrics.failed(_elapsed_ms(started))
            self.repository.update(session_id, state="failed", error_code="silent_audio")
            raise APIProblem(422, "silent_audio", str(error)) from error
        except InvalidAudioError as error:
            self.metrics.failed(_elapsed_ms(started))
            self.repository.update(session_id, state="failed", error_code="invalid_audio")
            raise APIProblem(422, "invalid_audio", str(error)) from error
        except EngineUnavailableError as error:
            self.metrics.failed(_elapsed_ms(started))
            self.repository.update(session_id, state="failed", error_code="engine_unavailable")
            raise APIProblem(503, "engine_unavailable", str(error), recoverable=True) from error
        except LanguageUnsupportedError as error:
            # Before the general handler below: this is a `TranscriptionProcessError`,
            # but retrying replays the same language against the same model, so the
            # audio is discarded rather than kept for a Retry that cannot succeed.
            self.metrics.failed(_elapsed_ms(started))
            self.repository.update(session_id, state="failed", error_code="language_unsupported")
            raise APIProblem(422, "language_unsupported", str(error)) from error
        except TranscriptionProcessError as error:
            self.metrics.failed(_elapsed_ms(started))
            self.repository.update(session_id, state="failed", error_code="transcription_failed")
            raise APIProblem(502, "transcription_failed", str(error), recoverable=True) from error
        except Exception:
            self.metrics.failed(_elapsed_ms(started))
            raise
        finally:
            normalized.unlink(missing_ok=True)
            self._transcription_slots.release()
            self.metrics.finished()

    async def transcribe_adhoc(self, source: Path, language: str) -> AdhocTranscription:
        """One-shot transcription for the WebUI test recorder (no session stored)."""
        await self._acquire_transcription_slot()
        normalized = self.normalized_dir / f"adhoc-{uuid4()}.wav"
        started = time.monotonic()
        normalization_ms = 0
        try:
            normalization_started = time.monotonic()
            await self.normalizer.normalize(
                source, normalized, self.settings.maximum_duration_seconds
            )
            normalization_ms = _elapsed_ms(normalization_started)
            audio_duration_ms = _wav_duration_ms(normalized)
            engine = self.engine_provider.current()
            inference_started = time.monotonic()
            raw_result = await engine.transcribe(
                normalized, TranscriptionOptions(language=language, style="raw")
            )
            outcome = _engine_outcome(raw_result, inference_started)
            name = (await engine.health()).name
            duration_ms = _elapsed_ms(started)
            timing = _pipeline_timing(
                duration_ms,
                normalization_ms,
                outcome,
                audio_duration_ms,
                name,
            )
            self.metrics.succeeded(duration_ms, timing)
            return AdhocTranscription(outcome.text.strip(), name, timing)
        except SilentAudioError as error:
            self.metrics.failed(_elapsed_ms(started))
            raise APIProblem(422, "silent_audio", str(error)) from error
        except InvalidAudioError as error:
            self.metrics.failed(_elapsed_ms(started))
            raise APIProblem(422, "invalid_audio", str(error)) from error
        except EngineUnavailableError as error:
            self.metrics.failed(_elapsed_ms(started))
            raise APIProblem(503, "engine_unavailable", str(error), recoverable=True) from error
        except LanguageUnsupportedError as error:
            self.metrics.failed(_elapsed_ms(started))
            raise APIProblem(422, "language_unsupported", str(error)) from error
        except TranscriptionProcessError as error:
            self.metrics.failed(_elapsed_ms(started))
            raise APIProblem(502, "transcription_failed", str(error), recoverable=True) from error
        except Exception:
            self.metrics.failed(_elapsed_ms(started))
            raise
        finally:
            normalized.unlink(missing_ok=True)
            self._transcription_slots.release()
            self.metrics.finished()

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

    async def _acquire_transcription_slot(self) -> None:
        self.metrics.queued()
        try:
            await asyncio.wait_for(self._transcription_slots.acquire(), timeout=0.05)
        except TimeoutError as error:
            self.metrics.rejected()
            raise APIProblem(
                503,
                "engine_overloaded",
                "The local transcription engine is busy.",
                recoverable=True,
            ) from error
        except BaseException:
            self.metrics.cancelled()
            raise
        self.metrics.started()

    def _safe_audio_path(self, audio_name: str) -> Path:
        if Path(audio_name).name != audio_name:
            raise APIProblem(500, "invalid_storage_reference", "Stored audio reference is invalid.")
        return self.upload_dir / audio_name


def conservative_cleanup(text: str) -> str:
    """Backward-compatible name for the original clean transcript mode."""
    return apply_writing_style(text, "clean")


def _elapsed_ms(started: float) -> int:
    return max(0, int((time.monotonic() - started) * 1000))


@dataclass(frozen=True, slots=True)
class AdhocTranscription:
    transcript: str
    engine: str
    timing: PipelineTiming


def _engine_outcome(
    result: str | EngineTranscription,
    inference_started: float,
) -> EngineTranscription:
    if isinstance(result, EngineTranscription):
        return result
    return EngineTranscription(text=result, inference_ms=_elapsed_ms(inference_started))


def _wav_duration_ms(path: Path) -> int:
    try:
        with wave.open(str(path), "rb") as source:
            frame_rate = source.getframerate()
            return round(source.getnframes() * 1000 / frame_rate) if frame_rate else 0
    except (OSError, EOFError, wave.Error):
        return 0


def _pipeline_timing(
    total_ms: int,
    normalization_ms: int,
    outcome: EngineTranscription,
    audio_duration_ms: int,
    engine: str,
) -> PipelineTiming:
    inference_ms = outcome.inference_ms
    rtf = round(inference_ms / audio_duration_ms, 3) if audio_duration_ms else None
    return PipelineTiming(
        total_ms=total_ms,
        normalization_ms=normalization_ms,
        model_load_ms=outcome.model_load_ms,
        inference_ms=inference_ms,
        audio_duration_ms=audio_duration_ms,
        real_time_factor=rtf,
        engine=engine,
        peak_memory_mb=_peak_memory_mb(),
    )


def _peak_memory_mb() -> float | None:
    try:
        usage = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    except (OSError, ValueError):
        return None
    divisor = 1024 * 1024 if platform.system() == "Darwin" else 1024
    return round(usage / divisor, 1)
