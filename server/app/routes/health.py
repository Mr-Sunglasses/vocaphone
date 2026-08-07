from __future__ import annotations

from fastapi import APIRouter, Depends, Response

from app.context import GatewayContext, get_context
from app.engine_state import active_catalog_model
from app.models.base import StreamingEngine
from app.schemas import HealthResponse, LivenessResponse, ReadinessResponse

router = APIRouter()


@router.get("/health", response_model=HealthResponse)
async def health(ctx: GatewayContext = Depends(get_context)) -> HealthResponse:
    state = await ctx.readiness.probe()
    selected_engine = ctx.engine_provider.current()
    active_model = active_catalog_model(ctx)
    languages: tuple[str, ...] = ()
    if active_model is not None:
        # Moonshine keeps its single language in the singular field.
        languages = active_model.language_codes or (
            (active_model.language_code,) if active_model.language_code else ()
        )
    return HealthResponse(
        engine_ready=state.ready,
        engine=state.name,
        streaming_supported=(
            state.ready
            and isinstance(selected_engine, StreamingEngine)
            and selected_engine.supports_streaming
        ),
        languages=list(languages),
        detects_language_automatically=(
            active_model is not None and active_model.detects_language_automatically
        ),
    )


@router.get("/health/live", response_model=LivenessResponse)
async def liveness(ctx: GatewayContext = Depends(get_context)) -> LivenessResponse:
    return LivenessResponse(uptime_seconds=ctx.service.metrics.snapshot().uptime_seconds)


@router.get("/health/ready", response_model=ReadinessResponse)
async def ready(
    response: Response, ctx: GatewayContext = Depends(get_context)
) -> ReadinessResponse:
    details = await ctx.readiness.details()
    if not details.health.ready:
        response.status_code = 503
    return ReadinessResponse(
        status="ready" if details.health.ready else "not_ready",
        engine_ready=details.health.ready,
        engine=details.health.name,
        probe_age_seconds=round(details.checked_age_seconds, 3),
        warmup_state=details.warmup_state,
    )
