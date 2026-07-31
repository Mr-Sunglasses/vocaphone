from __future__ import annotations

import hmac
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from uuid import UUID

from fastapi import Depends, FastAPI, Header, Request, Response
from fastapi.responses import JSONResponse

from app.audio import (
    ALLOWED_AUDIO_TYPES,
    FFmpegNormalizer,
    atomic_upload_path,
    complete_atomic_upload,
)
from app.config import Settings
from app.errors import APIProblem
from app.models.base import AudioNormalizer, TranscriptionEngine
from app.models.handy import HandyEngine
from app.models.whisper_cpp import WhisperCppEngine
from app.schemas import (
    CreateSessionRequest,
    DeleteResponse,
    ErrorDetail,
    ErrorEnvelope,
    HealthResponse,
    ModelResponse,
    SessionResponse,
)
from app.service import TranscriptionService
from app.storage import SessionRepository, StoredSession


def create_app(
    settings: Settings | None = None,
    *,
    engine: TranscriptionEngine | None = None,
    normalizer: AudioNormalizer | None = None,
) -> FastAPI:
    configured = settings or Settings.from_env()
    repository = SessionRepository(configured.data_dir / "sessions.sqlite3")
    repository.initialize()
    selected_engine = engine or select_engine(configured)
    service = TranscriptionService(
        configured,
        repository,
        selected_engine,
        normalizer or FFmpegNormalizer(),
    )

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        service.cleanup_expired()
        yield

    app = FastAPI(
        title="Local Flow Gateway",
        version="0.1.0",
        docs_url=None,
        redoc_url=None,
        lifespan=lifespan,
    )
    app.state.settings = configured
    app.state.service = service
    app.state.engine = selected_engine

    @app.exception_handler(APIProblem)
    async def api_problem_handler(_: Request, problem: APIProblem) -> JSONResponse:
        envelope = ErrorEnvelope(
            error=ErrorDetail(
                code=problem.code,
                message=problem.message,
                recoverable=problem.recoverable,
            )
        )
        return JSONResponse(status_code=problem.status_code, content=envelope.model_dump())

    def require_token(authorization: str | None = Header(default=None)) -> None:
        prefix = "Bearer "
        supplied = (
            authorization[len(prefix) :]
            if authorization and authorization.startswith(prefix)
            else ""
        )
        if not hmac.compare_digest(supplied, configured.token):
            raise APIProblem(401, "unauthorized", "A valid bearer token is required.")

    @app.get("/health", response_model=HealthResponse)
    async def health() -> HealthResponse:
        state = await selected_engine.health()
        return HealthResponse(engine_ready=state.ready, engine=state.name)

    @app.get(
        "/v1/models",
        response_model=list[ModelResponse],
        dependencies=[Depends(require_token)],
    )
    async def models() -> list[ModelResponse]:
        state = await selected_engine.health()
        return [ModelResponse(id=state.name, ready=state.ready, local=True)]

    @app.post(
        "/v1/sessions",
        response_model=SessionResponse,
        dependencies=[Depends(require_token)],
    )
    async def create_session(body: CreateSessionRequest) -> SessionResponse:
        stored = repository.create_or_get(body.client_session_id, body.language, body.style)
        return _response(stored)

    @app.get(
        "/v1/sessions/{session_id}",
        response_model=SessionResponse,
        dependencies=[Depends(require_token)],
    )
    async def get_session(session_id: UUID) -> SessionResponse:
        return _response(service.require(session_id))

    @app.put(
        "/v1/sessions/{session_id}/audio",
        response_model=SessionResponse,
        dependencies=[Depends(require_token)],
    )
    async def upload_audio(
        session_id: UUID,
        request: Request,
        content_type: str | None = Header(default=None),
        content_length: int | None = Header(default=None),
    ) -> SessionResponse:
        stored = service.require(session_id)
        if stored.state == "completed":
            return _response(stored)
        normalized_type = (content_type or "").split(";", maxsplit=1)[0].lower()
        suffix = ALLOWED_AUDIO_TYPES.get(normalized_type)
        if suffix is None:
            raise APIProblem(415, "unsupported_audio_type", "This audio type is not supported.")
        if content_length is not None and content_length > configured.maximum_upload_bytes:
            raise APIProblem(413, "audio_too_large", "The recording exceeds the upload limit.")

        temporary, final = atomic_upload_path(service.upload_dir, str(session_id).lower(), suffix)
        received = 0
        try:
            with temporary.open("wb") as output:
                async for chunk in request.stream():
                    received += len(chunk)
                    if received > configured.maximum_upload_bytes:
                        raise APIProblem(
                            413, "audio_too_large", "The recording exceeds the upload limit."
                        )
                    output.write(chunk)
            if received < 128:
                raise APIProblem(422, "audio_empty", "The recording is empty.")
            complete_atomic_upload(temporary, final)
        except Exception:
            temporary.unlink(missing_ok=True)
            raise
        updated = repository.update(
            session_id,
            state="uploaded",
            audio_name=final.name,
            transcript=None,
            error_code=None,
            preserve_audio_name=False,
        )
        return _response(updated)

    @app.post(
        "/v1/sessions/{session_id}/finish",
        response_model=SessionResponse,
        dependencies=[Depends(require_token)],
    )
    async def finish(session_id: UUID) -> SessionResponse:
        return _response(await service.finish(session_id))

    @app.post(
        "/v1/sessions/{session_id}/retry",
        response_model=SessionResponse,
        dependencies=[Depends(require_token)],
    )
    async def retry(session_id: UUID) -> SessionResponse:
        stored = service.require(session_id)
        if stored.state not in {"failed", "uploaded", "completed"}:
            raise APIProblem(409, "session_not_retryable", "This session cannot be retried.")
        return _response(await service.finish(session_id))

    @app.delete(
        "/v1/sessions/{session_id}",
        response_model=DeleteResponse,
        dependencies=[Depends(require_token)],
    )
    async def delete_session(session_id: UUID, response: Response) -> DeleteResponse:
        deleted = service.delete(session_id)
        if not deleted:
            response.status_code = 404
        return DeleteResponse(deleted=deleted)

    return app


def select_engine(settings: Settings) -> TranscriptionEngine:
    if settings.engine not in {"auto", "handy", "whisper.cpp"}:
        raise RuntimeError("LOCALFLOW_ENGINE must be auto, handy, or whisper.cpp.")
    if settings.engine == "handy" or (
        settings.engine == "auto" and settings.handy_binary.is_file()
    ):
        return HandyEngine(
            settings.handy_binary,
            settings.handy_model,
            fallback_model=settings.handy_fallback_model,
        )
    return WhisperCppEngine(settings.whisper_binary, settings.whisper_model)


def _response(stored: StoredSession) -> SessionResponse:
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
