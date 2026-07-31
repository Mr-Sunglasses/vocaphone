from __future__ import annotations

from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field


class CreateSessionRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    client_session_id: UUID
    language: str = Field(default="auto", max_length=20, pattern=r"^[A-Za-z-]+$|^auto$")
    style: Literal["raw", "clean"] = "raw"


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


class ErrorDetail(BaseModel):
    code: str
    message: str
    recoverable: bool


class ErrorEnvelope(BaseModel):
    error: ErrorDetail
