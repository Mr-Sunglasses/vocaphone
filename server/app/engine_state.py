from __future__ import annotations

from pathlib import Path

from app.catalog import CatalogModel
from app.context import GatewayContext
from app.system import detect_system, engine_runs_on


def engine_id(ctx: GatewayContext) -> str:
    if ctx.engine_manager is not None:
        return ctx.engine_manager.runtime_config.engine
    return "custom"


def available_engines(ctx: GatewayContext) -> list[str]:
    if ctx.engine_manager is None:
        return ["custom"]
    settings = ctx.settings
    system = detect_system(
        whisper_binary=settings.whisper_binary,
        whisperkit_binary=settings.whisperkit_binary,
        handy_binary=settings.handy_binary,
        vocamac_app=settings.vocamac_app,
    )
    engines = ["auto", "sherpa-onnx", "faster-whisper", "moonshine", "whisper.cpp"]
    # The desktop-app and Apple-native adapters only exist on a matching host.
    engines.extend(
        engine
        for engine in ("vocamac", "handy", "whisperkit", "mlx-audio")
        if engine_runs_on(
            engine,
            is_mac=system.os_name == "Darwin",
            is_apple_silicon=system.is_apple_silicon,
        )
    )
    return engines


def active_model_path(ctx: GatewayContext) -> Path | None:
    if ctx.engine_manager is None:
        return None
    config = ctx.engine_manager.runtime_config
    if config.engine == "moonshine":
        return ctx.manager.installed_path(config.moonshine_model)
    if config.engine == "sherpa-onnx" and config.sherpa_model:
        return ctx.manager.installed_path(config.sherpa_model)
    if config.engine == "mlx-audio" and config.mlx_audio_model:
        return ctx.manager.installed_path(config.mlx_audio_model)
    if config.whisper_model:
        return Path(config.whisper_model)
    if config.whisperkit_model:
        return Path(config.whisperkit_model)
    if config.faster_whisper_model:
        return Path(config.faster_whisper_model)
    return None


def active_catalog_model(ctx: GatewayContext) -> CatalogModel | None:
    """The catalog entry behind the running engine, if it came from the catalog.

    sherpa-onnx and MLX engines hold their entry directly; the others are
    configured by path, so those are matched back through the installed list.
    Returns None for an imported model or when nothing is selected, which the
    clients read as "no restriction".
    """
    engine = ctx.engine_provider.current()
    held = getattr(engine, "catalog_model", None)
    if isinstance(held, CatalogModel):
        return held
    active = active_model_path(ctx)
    if active is None:
        return None
    for installed in ctx.manager.installed():
        if installed.path == active:
            return ctx.manager.catalog_model(installed.id)
    return None
