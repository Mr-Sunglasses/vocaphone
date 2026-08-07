from __future__ import annotations

from fastapi import APIRouter, Depends, Form, Response
from fastapi.responses import HTMLResponse

from app.admin_queries import token_entries
from app.context import BOOTSTRAP_TOKEN_ID, GatewayContext, get_context, require_token
from app.errors import APIProblem
from app.fragments.tokens import tokens_fragment
from app.schemas import (
    DeviceTokenCreateRequest,
    DeviceTokenCreateResponse,
    DeviceTokenEntry,
    DeviceTokenRevokeResponse,
)

router = APIRouter(dependencies=[Depends(require_token)])


def tokens_fragment_str(ctx: GatewayContext, *, new_token: tuple[str, str] | None = None) -> str:
    return tokens_fragment(token_entries(ctx), new_token=new_token)


@router.get("/v1/admin/tokens", response_model=list[DeviceTokenEntry])
async def list_admin_tokens(
    ctx: GatewayContext = Depends(get_context),
) -> list[DeviceTokenEntry]:
    return token_entries(ctx)


@router.post("/v1/admin/tokens", response_model=DeviceTokenCreateResponse)
async def create_admin_token(
    body: DeviceTokenCreateRequest, ctx: GatewayContext = Depends(get_context)
) -> DeviceTokenCreateResponse:
    record, plaintext = ctx.token_store.create(body.label)
    return DeviceTokenCreateResponse(
        id=record.id, label=record.label, token=plaintext, created_at=record.created_at
    )


@router.delete("/v1/admin/tokens/{token_id}", response_model=DeviceTokenRevokeResponse)
async def revoke_admin_token(
    token_id: str, response: Response, ctx: GatewayContext = Depends(get_context)
) -> DeviceTokenRevokeResponse:
    if token_id == BOOTSTRAP_TOKEN_ID:
        raise APIProblem(
            409,
            "bootstrap_token_not_revocable",
            "Rotate VOCAPHONE_TOKEN or its token file instead of revoking it here.",
        )
    revoked = ctx.token_store.revoke(token_id)
    if not revoked:
        response.status_code = 404
    return DeviceTokenRevokeResponse(revoked=revoked)


@router.post("/v1/admin/tokens/{token_id}/rotate", response_model=DeviceTokenCreateResponse)
async def rotate_admin_token(
    token_id: str, ctx: GatewayContext = Depends(get_context)
) -> DeviceTokenCreateResponse:
    if token_id == BOOTSTRAP_TOKEN_ID:
        raise APIProblem(
            409,
            "bootstrap_token_not_rotatable",
            "Rotate VOCAPHONE_TOKEN or its token file instead of rotating it here.",
        )
    rotated = ctx.token_store.rotate(token_id)
    if rotated is None:
        raise APIProblem(404, "token_not_found", "This device token no longer exists.")
    record, plaintext = rotated
    return DeviceTokenCreateResponse(
        id=record.id, label=record.label, token=plaintext, created_at=record.created_at
    )


@router.get("/ui/partials/tokens", response_class=HTMLResponse)
async def ui_tokens(ctx: GatewayContext = Depends(get_context)) -> HTMLResponse:
    return HTMLResponse(tokens_fragment_str(ctx))


@router.post("/ui/partials/tokens", response_class=HTMLResponse)
async def ui_create_token(
    label: str = Form(..., min_length=1, max_length=100),
    ctx: GatewayContext = Depends(get_context),
) -> HTMLResponse:
    record, plaintext = ctx.token_store.create(label)
    return HTMLResponse(tokens_fragment_str(ctx, new_token=(record.label, plaintext)))


@router.delete("/ui/partials/tokens/{token_id}", response_class=HTMLResponse)
async def ui_revoke_token(
    token_id: str, ctx: GatewayContext = Depends(get_context)
) -> HTMLResponse:
    if token_id == BOOTSTRAP_TOKEN_ID:
        raise APIProblem(
            409,
            "bootstrap_token_not_revocable",
            "Rotate VOCAPHONE_TOKEN or its token file instead of revoking it here.",
        )
    ctx.token_store.revoke(token_id)
    return HTMLResponse(tokens_fragment_str(ctx))


@router.post("/ui/partials/tokens/{token_id}/rotate", response_class=HTMLResponse)
async def ui_rotate_token(
    token_id: str, ctx: GatewayContext = Depends(get_context)
) -> HTMLResponse:
    if token_id == BOOTSTRAP_TOKEN_ID:
        raise APIProblem(
            409,
            "bootstrap_token_not_rotatable",
            "Rotate VOCAPHONE_TOKEN or its token file instead of rotating it here.",
        )
    rotated = ctx.token_store.rotate(token_id)
    if rotated is None:
        raise APIProblem(404, "token_not_found", "This device token no longer exists.")
    record, plaintext = rotated
    return HTMLResponse(tokens_fragment_str(ctx, new_token=(record.label, plaintext)))
