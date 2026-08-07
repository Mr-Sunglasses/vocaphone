from __future__ import annotations

from fastapi import APIRouter, Depends, Response
from fastapi.responses import HTMLResponse

from app.admin_queries import config_response, status_payload
from app.context import GatewayContext, get_context, require_token
from app.diagnostics import build_diagnostics_bundle
from app.engine_state import engine_id
from app.fragments.engine import engine_pill_fragment
from app.fragments.overview import operations_fragment, overview_fragment
from app.pairing_view import pairing_html
from app.schemas import AdminStatusResponse, DiagnosticsBundle, EngineStatus, ReadinessStatus
from app.serializers import metrics_status

router = APIRouter(dependencies=[Depends(require_token)])


@router.get("/v1/admin/status", response_model=AdminStatusResponse)
async def get_admin_status(ctx: GatewayContext = Depends(get_context)) -> AdminStatusResponse:
    return await status_payload(ctx)


@router.get("/v1/admin/diagnostics", response_model=DiagnosticsBundle)
async def get_admin_diagnostics(
    response: Response, ctx: GatewayContext = Depends(get_context)
) -> DiagnosticsBundle:
    bundle = build_diagnostics_bundle(await status_payload(ctx), config_response(ctx))
    filename = f"vocaphone-diagnostics-{bundle.generated_at:%Y%m%dT%H%M%SZ}.json"
    response.headers["Content-Disposition"] = f'attachment; filename="{filename}"'
    return bundle


@router.get("/ui/partials/overview", response_class=HTMLResponse)
async def ui_overview(ctx: GatewayContext = Depends(get_context)) -> HTMLResponse:
    status = await status_payload(ctx)
    return HTMLResponse(overview_fragment(status, pairing_html=pairing_html(ctx)))


@router.get("/ui/partials/operations", response_class=HTMLResponse)
async def ui_operations(ctx: GatewayContext = Depends(get_context)) -> HTMLResponse:
    metrics = ctx.service.metrics.snapshot()
    readiness_details = await ctx.readiness.details()
    return HTMLResponse(
        operations_fragment(
            metrics_status(metrics),
            ReadinessStatus(
                probe_age_seconds=round(readiness_details.checked_age_seconds, 3),
                warmup_state=readiness_details.warmup_state,
                warmed_bytes=readiness_details.warmed_bytes,
            ),
        )
    )


@router.get("/ui/partials/engine-pill", response_class=HTMLResponse)
async def ui_engine_pill(ctx: GatewayContext = Depends(get_context)) -> HTMLResponse:
    state = await ctx.readiness.probe()
    return HTMLResponse(
        engine_pill_fragment(EngineStatus(id=engine_id(ctx), name=state.name, ready=state.ready))
    )
