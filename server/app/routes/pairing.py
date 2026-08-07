from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends, Form, Query, Response
from fastapi.responses import HTMLResponse

from app.context import GatewayContext, get_context, require_token
from app.pairing import (
    decode_pairing_payload,
    discover_gateway_base_urls,
    encode_pairing_payload,
    qr_svg_for_payload,
)
from app.pairing_view import (
    forget_pairing_url,
    pairing_html,
    resolve_pairing_token,
    resolve_pairing_url,
)

router = APIRouter(dependencies=[Depends(require_token)])


@router.get("/v1/admin/pairing")
async def get_pairing(
    url: str | None = Query(default=None),
    token_id: str | None = Query(default=None),
    ctx: GatewayContext = Depends(get_context),
) -> dict[str, Any]:
    selected = resolve_pairing_url(ctx, url)
    _, token, _, _ = resolve_pairing_token(ctx, token_id)
    payload = encode_pairing_payload(selected, token)
    # Round-trip so clients and tests share one format.
    decoded = decode_pairing_payload(payload)
    return {
        "version": decoded.version,
        "url": decoded.url,
        "payload": payload,
        "candidates": discover_gateway_base_urls(ctx.settings.port),
    }


@router.get("/v1/admin/pairing/qr.svg", response_class=Response)
async def get_pairing_qr(
    url: str | None = Query(default=None),
    token_id: str | None = Query(default=None),
    ctx: GatewayContext = Depends(get_context),
) -> Response:
    selected = resolve_pairing_url(ctx, url)
    _, token, _, _ = resolve_pairing_token(ctx, token_id)
    payload = encode_pairing_payload(selected, token)
    svg = qr_svg_for_payload(payload)
    return Response(
        content=svg,
        media_type="image/svg+xml",
        headers={"Cache-Control": "no-store"},
    )


@router.get("/ui/partials/pairing", response_class=HTMLResponse)
async def ui_pairing(
    url: str | None = Query(default=None),
    token_id: str | None = Query(default=None),
    ctx: GatewayContext = Depends(get_context),
) -> HTMLResponse:
    return HTMLResponse(pairing_html(ctx, url, token_id, persist=True))


@router.post("/ui/partials/pairing/tokens", response_class=HTMLResponse)
async def ui_create_pairing_token(
    label: str = Form(..., min_length=1, max_length=100),
    url: str | None = Form(default=None),
    ctx: GatewayContext = Depends(get_context),
) -> HTMLResponse:
    record, _ = ctx.token_store.create(label)
    return HTMLResponse(pairing_html(ctx, url, record.id, persist=True))


@router.post("/ui/partials/pairing/tokens/{token_id}/rotate", response_class=HTMLResponse)
async def ui_rotate_pairing_token(
    token_id: str,
    url: str | None = Form(default=None),
    ctx: GatewayContext = Depends(get_context),
) -> HTMLResponse:
    rotated = ctx.token_store.rotate(token_id)
    resolved_id = rotated[0].id if rotated is not None else token_id
    return HTMLResponse(pairing_html(ctx, url, resolved_id, persist=True))


@router.delete("/ui/partials/pairing", response_class=HTMLResponse)
async def ui_forget_pairing(
    url: str = Query(...), ctx: GatewayContext = Depends(get_context)
) -> HTMLResponse:
    return HTMLResponse(forget_pairing_url(ctx, url))
