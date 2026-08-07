from __future__ import annotations

from app.metrics import MetricsSnapshot
from app.schemas import AdminModelEntry, OperationalMetricsStatus, SessionResponse
from app.storage import StoredSession


def session_response(stored: StoredSession) -> SessionResponse:
    return SessionResponse(
        session_id=stored.session_id,
        job_id=stored.job_id,
        state=stored.state,
        language=stored.language,
        style=stored.style,
        transcript=stored.transcript,
        error_code=stored.error_code,
        created_at=stored.created_at,
        updated_at=stored.updated_at,
    )


def metrics_status(metrics: MetricsSnapshot) -> OperationalMetricsStatus:
    pipeline = metrics.last_pipeline
    return OperationalMetricsStatus(
        uptime_seconds=metrics.uptime_seconds,
        queue_depth=metrics.queue_depth,
        active_transcriptions=metrics.active_transcriptions,
        concurrency_limit=metrics.concurrency_limit,
        successful_transcriptions=metrics.successful_transcriptions,
        failed_transcriptions=metrics.failed_transcriptions,
        rejected_transcriptions=metrics.rejected_transcriptions,
        average_latency_ms=metrics.average_latency_ms,
        last_latency_ms=metrics.last_latency_ms,
        normalization_ms=pipeline.normalization_ms if pipeline else None,
        model_load_ms=pipeline.model_load_ms if pipeline else None,
        inference_ms=pipeline.inference_ms if pipeline else None,
        audio_duration_ms=pipeline.audio_duration_ms if pipeline else None,
        real_time_factor=pipeline.real_time_factor if pipeline else None,
        peak_memory_mb=pipeline.peak_memory_mb if pipeline else None,
    )


def joined_stream_lines(lines: dict[int, str]) -> str:
    return " ".join(lines[key] for key in sorted(lines) if lines[key]).strip()


def model_covers(entry: AdminModelEntry, language: str) -> bool:
    """Whether a model can transcribe `language`.

    A model with no declared languages matches everything rather than nothing.
    No catalog entry is in that position today, but a user's own imported model
    is, and hiding an unlabelled model from every filter would make it look like
    the import had failed.
    """
    if not entry.language_codes:
        return True
    return language in entry.language_codes
