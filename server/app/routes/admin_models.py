from __future__ import annotations

from fastapi import APIRouter, Depends, Form, Response
from fastapi.responses import HTMLResponse

from app.admin_queries import filtered_model_entries, model_entries
from app.context import GatewayContext, get_context, require_token
from app.errors import APIProblem
from app.fragments.engine import engine_pill_oob
from app.fragments.models import models_fragment, models_list_fragment
from app.model_manager import DownloadInProgressError, UnknownModelError
from app.schemas import (
    AdminModelEntry,
    CustomDownloadRequest,
    DeleteResponse,
    DownloadResponse,
    EngineStatus,
    SelectModelResponse,
)

router = APIRouter(dependencies=[Depends(require_token)])


def _models_list_html(
    ctx: GatewayContext, installed_only: bool = False, language: str = ""
) -> HTMLResponse:
    entries = filtered_model_entries(ctx, installed_only, language)
    return HTMLResponse(models_list_fragment(entries, installed_only, language))


@router.get("/v1/admin/models", response_model=list[AdminModelEntry])
async def get_admin_models(
    installed_only: bool = False,
    language: str = "",
    ctx: GatewayContext = Depends(get_context),
) -> list[AdminModelEntry]:
    return filtered_model_entries(ctx, installed_only, language)


@router.post("/v1/admin/models/{model_id}/download", response_model=DownloadResponse)
async def start_model_download(
    model_id: str, ctx: GatewayContext = Depends(get_context)
) -> DownloadResponse:
    try:
        state = ctx.manager.start_download(model_id)
    except UnknownModelError as error:
        raise APIProblem(404, "unknown_model", "This model is not in the catalog.") from error
    except DownloadInProgressError as error:
        raise APIProblem(
            409, "download_in_progress", "This model is already downloading."
        ) from error
    return DownloadResponse(model_id=model_id, status=state.status)


@router.post("/v1/admin/models/custom", response_model=DownloadResponse)
async def start_custom_download(
    body: CustomDownloadRequest, ctx: GatewayContext = Depends(get_context)
) -> DownloadResponse:
    try:
        state = ctx.manager.start_custom_download(body.url)
    except ValueError as error:
        raise APIProblem(422, "invalid_model_url", str(error)) from error
    except DownloadInProgressError as error:
        raise APIProblem(409, "download_in_progress", str(error)) from error
    return DownloadResponse(model_id=state.model_id, status=state.status)


@router.post("/v1/admin/models/{model_id}/cancel", response_model=DownloadResponse)
async def cancel_model_download(
    model_id: str, ctx: GatewayContext = Depends(get_context)
) -> DownloadResponse:
    if not ctx.manager.cancel_download(model_id):
        raise APIProblem(409, "download_not_active", "This model is not currently downloading.")
    return DownloadResponse(model_id=model_id, status="cancelling")


@router.delete("/v1/admin/models/{model_id}", response_model=DeleteResponse)
async def delete_model(
    model_id: str, response: Response, ctx: GatewayContext = Depends(get_context)
) -> DeleteResponse:
    try:
        if ctx.engine_manager is not None:
            ctx.engine_manager.forget_if_active(model_id)
        deleted = ctx.manager.delete(model_id)
    except DownloadInProgressError as error:
        raise APIProblem(
            409, "download_in_progress", "Cancel the download before deleting."
        ) from error
    if not deleted:
        response.status_code = 404
    return DeleteResponse(deleted=deleted)


@router.post("/v1/admin/models/{model_id}/select", response_model=SelectModelResponse)
async def select_model(
    model_id: str, ctx: GatewayContext = Depends(get_context)
) -> SelectModelResponse:
    engine_manager = ctx.engine_manager
    if engine_manager is None:
        raise APIProblem(409, "engine_locked", "The engine was fixed at startup and cannot switch.")
    try:
        engine_manager.select_model(model_id)
    except KeyError as error:
        raise APIProblem(
            404, "model_not_installed", "Download this model before selecting it."
        ) from error
    await ctx.readiness.warmup()
    state = await ctx.readiness.probe()
    return SelectModelResponse(
        engine=EngineStatus(
            id=engine_manager.runtime_config.engine, name=state.name, ready=state.ready
        )
    )


@router.get("/ui/partials/models", response_class=HTMLResponse)
async def ui_models(ctx: GatewayContext = Depends(get_context)) -> HTMLResponse:
    return HTMLResponse(models_fragment(model_entries(ctx)))


@router.get("/ui/partials/models-list", response_class=HTMLResponse)
async def ui_models_list(
    installed_only: bool = False,
    language: str = "",
    ctx: GatewayContext = Depends(get_context),
) -> HTMLResponse:
    return _models_list_html(ctx, installed_only, language)


@router.post("/ui/partials/models/{model_id}/download", response_class=HTMLResponse)
async def ui_start_download(
    model_id: str,
    installed_only: bool = Form(False),
    language: str = Form(""),
    ctx: GatewayContext = Depends(get_context),
) -> HTMLResponse:
    try:
        ctx.manager.start_download(model_id)
    except UnknownModelError as error:
        raise APIProblem(404, "unknown_model", "This model is not in the catalog.") from error
    except DownloadInProgressError as error:
        raise APIProblem(
            409, "download_in_progress", "This model is already downloading."
        ) from error
    return _models_list_html(ctx, installed_only, language)


@router.post("/ui/partials/models/custom", response_class=HTMLResponse)
async def ui_custom_download(
    url: str = Form(...),
    installed_only: bool = Form(False),
    language: str = Form(""),
    ctx: GatewayContext = Depends(get_context),
) -> HTMLResponse:
    try:
        ctx.manager.start_custom_download(url)
    except ValueError as error:
        raise APIProblem(422, "invalid_model_url", str(error)) from error
    except DownloadInProgressError as error:
        raise APIProblem(409, "download_in_progress", str(error)) from error
    return _models_list_html(ctx, installed_only, language)


@router.post("/ui/partials/models/{model_id}/cancel", response_class=HTMLResponse)
async def ui_cancel_download(
    model_id: str,
    installed_only: bool = Form(False),
    language: str = Form(""),
    ctx: GatewayContext = Depends(get_context),
) -> HTMLResponse:
    ctx.manager.cancel_download(model_id)
    return _models_list_html(ctx, installed_only, language)


@router.delete("/ui/partials/models/{model_id}", response_class=HTMLResponse)
async def ui_delete_model(
    model_id: str,
    installed_only: bool = Form(False),
    language: str = Form(""),
    ctx: GatewayContext = Depends(get_context),
) -> HTMLResponse:
    try:
        if ctx.engine_manager is not None:
            ctx.engine_manager.forget_if_active(model_id)
        ctx.manager.delete(model_id)
    except DownloadInProgressError as error:
        raise APIProblem(
            409, "download_in_progress", "Cancel the download before deleting."
        ) from error
    return _models_list_html(ctx, installed_only, language)


@router.post("/ui/partials/models/{model_id}/select", response_class=HTMLResponse)
async def ui_select_model(
    model_id: str,
    installed_only: bool = Form(False),
    language: str = Form(""),
    ctx: GatewayContext = Depends(get_context),
) -> HTMLResponse:
    engine_manager = ctx.engine_manager
    if engine_manager is None:
        raise APIProblem(409, "engine_locked", "The engine was fixed at startup and cannot switch.")
    try:
        engine_manager.select_model(model_id)
    except KeyError as error:
        raise APIProblem(
            404, "model_not_installed", "Download this model before selecting it."
        ) from error
    await ctx.readiness.warmup()
    state = await ctx.readiness.probe()
    entries = model_entries(ctx)
    if installed_only:
        entries = [entry for entry in entries if entry.state == "installed"]
    return HTMLResponse(
        models_list_fragment(entries, installed_only)
        + engine_pill_oob(
            EngineStatus(
                id=engine_manager.runtime_config.engine, name=state.name, ready=state.ready
            )
        )
    )
