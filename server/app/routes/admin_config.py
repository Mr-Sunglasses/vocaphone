from __future__ import annotations

import time

from fastapi import APIRouter, Depends, Form, Header, Query, Request
from fastapi.responses import HTMLResponse

from app.admin_queries import config_response
from app.audio import ALLOWED_AUDIO_TYPES, atomic_upload_path, complete_atomic_upload
from app.context import TOKEN_FILE_HINT, GatewayContext, get_context, require_token
from app.errors import APIProblem
from app.fragments.engine import engine_update_fragment
from app.fragments.settings import settings_fragment
from app.fragments.test_panel import test_fragment
from app.routes.admin_tokens import tokens_fragment_str
from app.schemas import (
    ConfigResponse,
    ConfigUpdateRequest,
    EngineStatus,
    SelectModelResponse,
    TestTranscriptionResponse,
)

router = APIRouter(dependencies=[Depends(require_token)])


@router.get("/v1/admin/config", response_model=ConfigResponse)
async def get_config(ctx: GatewayContext = Depends(get_context)) -> ConfigResponse:
    return config_response(ctx)


@router.put("/v1/admin/config", response_model=SelectModelResponse)
async def update_config(
    body: ConfigUpdateRequest, ctx: GatewayContext = Depends(get_context)
) -> SelectModelResponse:
    engine_manager = ctx.engine_manager
    if engine_manager is None:
        raise APIProblem(409, "engine_locked", "The engine was fixed at startup and cannot switch.")
    try:
        engine_manager.configure(
            body.engine, body.compute_device, body.compute_type, body.cpu_threads
        )
    except ValueError as error:
        raise APIProblem(422, "invalid_engine", str(error)) from error
    await ctx.readiness.warmup()
    state = await ctx.readiness.probe()
    return SelectModelResponse(
        engine=EngineStatus(id=body.engine, name=state.name, ready=state.ready)
    )


@router.post("/v1/admin/test-transcription", response_model=TestTranscriptionResponse)
async def test_transcription(
    request: Request,
    language: str = Query(default="auto", pattern=r"^[A-Za-z-]+$|^auto$"),
    content_type: str | None = Header(default=None),
    content_length: int | None = Header(default=None),
    ctx: GatewayContext = Depends(get_context),
) -> TestTranscriptionResponse:
    normalized_type = (content_type or "").split(";", maxsplit=1)[0].lower()
    suffix = ALLOWED_AUDIO_TYPES.get(normalized_type)
    if suffix is None:
        raise APIProblem(415, "unsupported_audio_type", "This audio type is not supported.")
    maximum_upload_bytes = ctx.settings.maximum_upload_bytes
    if content_length is not None and content_length > maximum_upload_bytes:
        raise APIProblem(413, "audio_too_large", "The recording exceeds the upload limit.")
    upload_dir = ctx.settings.data_dir / "test-uploads"
    temporary, final = atomic_upload_path(upload_dir, f"test-{int(time.time() * 1000)}", suffix)
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
    try:
        result = await ctx.service.transcribe_adhoc(final, language)
    finally:
        final.unlink(missing_ok=True)
    return TestTranscriptionResponse(
        transcript=result.transcript,
        engine=result.engine,
        duration_ms=result.timing.total_ms,
        normalization_ms=result.timing.normalization_ms,
        model_load_ms=result.timing.model_load_ms,
        inference_ms=result.timing.inference_ms,
        audio_duration_ms=result.timing.audio_duration_ms,
        real_time_factor=result.timing.real_time_factor,
        peak_memory_mb=result.timing.peak_memory_mb,
    )


@router.get("/ui/partials/settings", response_class=HTMLResponse)
async def ui_settings(ctx: GatewayContext = Depends(get_context)) -> HTMLResponse:
    paths = [
        ("Data directory", str(ctx.settings.data_dir)),
        ("Models directory", str(ctx.manager.models_dir)),
        ("WebUI config file", str(ctx.config_path)),
        ("Token file", TOKEN_FILE_HINT),
    ]
    return HTMLResponse(
        settings_fragment(
            config_response(ctx),
            paths,
            ctx.settings.bind_host,
            ctx.settings.port,
            tokens_fragment_str(ctx),
        )
    )


@router.put("/ui/partials/config", response_class=HTMLResponse)
async def ui_update_config(
    engine: str = Form(...),
    compute_device: str = Form("auto"),
    compute_type: str = Form("auto"),
    cpu_threads: int = Form(0),
    ctx: GatewayContext = Depends(get_context),
) -> HTMLResponse:
    engine_manager = ctx.engine_manager
    if engine_manager is None:
        raise APIProblem(409, "engine_locked", "The engine was fixed at startup and cannot switch.")
    try:
        engine_manager.configure(engine, compute_device, compute_type, cpu_threads)
    except ValueError as error:
        raise APIProblem(422, "invalid_engine", str(error)) from error
    await ctx.readiness.warmup()
    state = await ctx.readiness.probe()
    return HTMLResponse(
        engine_update_fragment(
            EngineStatus(id=engine, name=state.name, ready=state.ready),
            "Engine preference saved.",
        )
    )


@router.get("/ui/partials/test", response_class=HTMLResponse)
async def ui_test(ctx: GatewayContext = Depends(get_context)) -> HTMLResponse:
    return HTMLResponse(test_fragment(ctx.settings.maximum_duration_seconds))
