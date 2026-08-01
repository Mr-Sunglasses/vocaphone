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


class AdminModelEntry(BaseModel):
    id: str
    engine: str
    label: str
    size_bytes: int
    languages: str
    quality: str
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


class ConfigUpdateRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    engine: Literal["auto", "handy", "whisper.cpp", "whisperkit"]


class SelectModelResponse(BaseModel):
    engine: EngineStatus


class TestTranscriptionResponse(BaseModel):
    transcript: str
    engine: str
    duration_ms: int


class ErrorDetail(BaseModel):
    code: str
    message: str
    recoverable: bool


class ErrorEnvelope(BaseModel):
    error: ErrorDetail
