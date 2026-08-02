from __future__ import annotations

from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field


class CreateSessionRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    client_session_id: UUID
    language: str = Field(default="auto", max_length=20, pattern=r"^[A-Za-z-]+$|^auto$")
    style: Literal[
        "raw",
        "clean",
        "formal",
        "casual",
        "very_casual",
        "excited",
    ] = "casual"


class SessionResponse(BaseModel):
    session_id: UUID
    job_id: str
    state: str
    language: str
    style: str
    transcript: str | None = None
    error_code: str | None = None
    created_at: datetime
    updated_at: datetime


class HealthResponse(BaseModel):
    status: Literal["ok"] = "ok"
    engine_ready: bool
    engine: str
    streaming_supported: bool


class LivenessResponse(BaseModel):
    status: Literal["ok"] = "ok"
    uptime_seconds: int


class ReadinessResponse(BaseModel):
    status: Literal["ready", "not_ready"]
    engine_ready: bool
    engine: str
    probe_age_seconds: float
    warmup_state: Literal["pending", "warming", "complete", "unsupported", "unavailable", "failed"]


class ModelResponse(BaseModel):
    id: str
    ready: bool
    local: Literal[True] = True


class DeleteResponse(BaseModel):
    deleted: bool


class DependencyStatus(BaseModel):
    name: str
    available: bool
    path: str | None = None
    install_hint: str | None = None


class SystemStatus(BaseModel):
    os: str
    arch: str
    chip: str
    ram_gb: float
    is_apple_silicon: bool
    logical_cpus: int
    effective_cpus: float
    containerized: bool
    accelerators: list[str]
    cpu_features: list[str]


class EngineStatus(BaseModel):
    id: str
    name: str
    ready: bool


class PathStatus(BaseModel):
    data_dir: str
    models_dir: str
    config_file: str
    token_file: str


class SetupChecklist(BaseModel):
    token_configured: bool
    ffmpeg_available: bool
    engine_binary_available: bool
    model_installed: bool
    engine_ready: bool


class OperationalMetricsStatus(BaseModel):
    uptime_seconds: int
    queue_depth: int
    active_transcriptions: int
    concurrency_limit: int
    successful_transcriptions: int
    failed_transcriptions: int
    rejected_transcriptions: int
    average_latency_ms: int | None
    last_latency_ms: int | None
    normalization_ms: int | None = None
    model_load_ms: int | None = None
    inference_ms: int | None = None
    audio_duration_ms: int | None = None
    real_time_factor: float | None = None
    peak_memory_mb: float | None = None


class ReadinessStatus(BaseModel):
    probe_age_seconds: float
    warmup_state: Literal["pending", "warming", "complete", "unsupported", "unavailable", "failed"]
    warmed_bytes: int


class AdminStatusResponse(BaseModel):
    status: Literal["ok"] = "ok"
    version: str
    engine: EngineStatus
    system: SystemStatus
    dependencies: list[DependencyStatus]
    paths: PathStatus
    bind_host: str
    port: int
    setup: SetupChecklist
    metrics: OperationalMetricsStatus
    readiness: ReadinessStatus


class AdminModelEntry(BaseModel):
    id: str
    engine: str
    label: str
    size_bytes: int
    languages: str
    quality: str
    family: str
    description: str
    source: str
    supports_streaming: bool = False
    license_name: str = "See model source"
    commercial_use: bool = True
    state: Literal["installed", "downloading", "not_installed"]
    active: bool
    recommended: bool
    progress: float | None = None
    downloaded_bytes: int | None = None
    total_bytes: int | None = None
    error: str | None = None


class CustomDownloadRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    url: str = Field(min_length=12, max_length=2000)


class DownloadResponse(BaseModel):
    model_id: str
    status: str


class ConfigResponse(BaseModel):
    engine: str
    available_engines: list[str]
    whisper_model: str | None = None
    whisperkit_model: str | None = None
    faster_whisper_model: str | None = None
    moonshine_model: str = "moonshine:en"
    moonshine_language: str = "en"
    sherpa_model: str | None = None
    mlx_audio_model: str | None = None
    compute_device: str = "auto"
    compute_type: str = "auto"
    cpu_threads: int = 0


class ConfigUpdateRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    engine: Literal[
        "auto",
        "handy",
        "whisper.cpp",
        "whisperkit",
        "faster-whisper",
        "moonshine",
        "sherpa-onnx",
        "mlx-audio",
    ]
    compute_device: Literal["auto", "cpu", "cuda"] = "auto"
    compute_type: Literal["auto", "int8", "int8_float16", "float16", "float32"] = "auto"
    cpu_threads: int = Field(default=0, ge=0, le=256)


class SelectModelResponse(BaseModel):
    engine: EngineStatus


class TestTranscriptionResponse(BaseModel):
    transcript: str
    engine: str
    duration_ms: int
    normalization_ms: int
    model_load_ms: int
    inference_ms: int
    audio_duration_ms: int
    real_time_factor: float | None
    peak_memory_mb: float | None


class ErrorDetail(BaseModel):
    code: str
    message: str
    recoverable: bool


class ErrorEnvelope(BaseModel):
    error: ErrorDetail
