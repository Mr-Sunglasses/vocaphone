from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, Header, Request, Response

from app.audio import ALLOWED_AUDIO_TYPES, atomic_upload_path, complete_atomic_upload
from app.context import GatewayContext, get_context, require_token
from app.errors import APIProblem
from app.schemas import CreateSessionRequest, DeleteResponse, ModelResponse, SessionResponse
from app.serializers import session_response

router = APIRouter(dependencies=[Depends(require_token)])


@router.get("/v1/models", response_model=list[ModelResponse])
async def models(ctx: GatewayContext = Depends(get_context)) -> list[ModelResponse]:
    state = await ctx.readiness.probe()
    return [ModelResponse(id=state.name, ready=state.ready, local=True)]


@router.post("/v1/sessions", response_model=SessionResponse)
async def create_session(
    body: CreateSessionRequest, ctx: GatewayContext = Depends(get_context)
) -> SessionResponse:
    stored = ctx.repository.create_or_get(body.client_session_id, body.language, body.style)
    return session_response(stored)


@router.get("/v1/sessions/{session_id}", response_model=SessionResponse)
async def get_session(
    session_id: UUID, ctx: GatewayContext = Depends(get_context)
) -> SessionResponse:
    return session_response(ctx.service.require(session_id))


@router.put("/v1/sessions/{session_id}/audio", response_model=SessionResponse)
async def upload_audio(
    session_id: UUID,
    request: Request,
    content_type: str | None = Header(default=None),
    content_length: int | None = Header(default=None),
    ctx: GatewayContext = Depends(get_context),
) -> SessionResponse:
    stored = ctx.service.require(session_id)
    if stored.state == "completed":
        return session_response(stored)
    normalized_type = (content_type or "").split(";", maxsplit=1)[0].lower()
    suffix = ALLOWED_AUDIO_TYPES.get(normalized_type)
    if suffix is None:
        raise APIProblem(415, "unsupported_audio_type", "This audio type is not supported.")
    maximum_upload_bytes = ctx.settings.maximum_upload_bytes
    if content_length is not None and content_length > maximum_upload_bytes:
        raise APIProblem(413, "audio_too_large", "The recording exceeds the upload limit.")

    temporary, final = atomic_upload_path(ctx.service.upload_dir, str(session_id).lower(), suffix)
    received = 0
    try:
        with temporary.open("wb") as output:
            async for chunk in request.stream():
                received += len(chunk)
                if received > maximum_upload_bytes:
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
    updated = ctx.repository.update(
        session_id,
        state="uploaded",
        audio_name=final.name,
        transcript=None,
        error_code=None,
        preserve_audio_name=False,
    )
    return session_response(updated)


@router.post("/v1/sessions/{session_id}/finish", response_model=SessionResponse)
async def finish(session_id: UUID, ctx: GatewayContext = Depends(get_context)) -> SessionResponse:
    return session_response(await ctx.service.finish(session_id))


@router.post("/v1/sessions/{session_id}/retry", response_model=SessionResponse)
async def retry(session_id: UUID, ctx: GatewayContext = Depends(get_context)) -> SessionResponse:
    stored = ctx.service.require(session_id)
    if stored.state not in {"failed", "uploaded", "completed"}:
        raise APIProblem(409, "session_not_retryable", "This session cannot be retried.")
    return session_response(await ctx.service.finish(session_id))


@router.delete("/v1/sessions/{session_id}", response_model=DeleteResponse)
async def delete_session(
    session_id: UUID, response: Response, ctx: GatewayContext = Depends(get_context)
) -> DeleteResponse:
    deleted = ctx.service.delete(session_id)
    if not deleted:
        response.status_code = 404
    return DeleteResponse(deleted=deleted)
