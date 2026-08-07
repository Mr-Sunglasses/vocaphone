from __future__ import annotations

import importlib.util
from typing import Literal

from app.catalog import language_names, recommended_ids
from app.context import BOOTSTRAP_TOKEN_ID, TOKEN_FILE_HINT, VERSION, GatewayContext
from app.engine_state import active_model_path, available_engines, engine_id
from app.schemas import (
    AdminModelEntry,
    AdminStatusResponse,
    ConfigResponse,
    DependencyStatus,
    DeviceTokenEntry,
    EngineStatus,
    PathStatus,
    ReadinessStatus,
    SetupChecklist,
    SystemStatus,
)
from app.serializers import metrics_status, model_covers
from app.system import detect_system


async def status_payload(ctx: GatewayContext) -> AdminStatusResponse:
    settings = ctx.settings
    system = detect_system(
        whisper_binary=settings.whisper_binary,
        whisperkit_binary=settings.whisperkit_binary,
        handy_binary=settings.handy_binary,
        vocamac_app=settings.vocamac_app,
    )
    is_mac = system.os_name == "Darwin"
    dependencies = [
        DependencyStatus(
            name="FFmpeg",
            available=system.ffmpeg_path is not None,
            path=system.ffmpeg_path,
            install_hint=(
                "brew install ffmpeg"
                if is_mac
                else "Install FFmpeg with your Linux package manager"
            ),
        ),
        DependencyStatus(
            name="whisper.cpp CLI",
            available=system.whisper_cpp_path is not None,
            path=system.whisper_cpp_path,
            install_hint=(
                "brew install whisper-cpp"
                if is_mac
                else "Included in Docker or build whisper.cpp from source"
            ),
        ),
        DependencyStatus(
            name="faster-whisper",
            available=importlib.util.find_spec("faster_whisper") is not None,
            path="Python package" if importlib.util.find_spec("faster_whisper") else None,
            install_hint="Install localflow-gateway[engines] or use the Docker image",
        ),
        DependencyStatus(
            name="Moonshine Voice",
            available=importlib.util.find_spec("moonshine_voice") is not None,
            path="Python package" if importlib.util.find_spec("moonshine_voice") else None,
            install_hint="Install localflow-gateway[engines] or use the Docker image",
        ),
        DependencyStatus(
            name="sherpa-onnx",
            available=importlib.util.find_spec("sherpa_onnx") is not None,
            path="Python package" if importlib.util.find_spec("sherpa_onnx") else None,
            install_hint="Install localflow-gateway[engines] or use the Docker image",
        ),
        DependencyStatus(
            name="MLX Audio",
            available=(
                system.is_apple_silicon and importlib.util.find_spec("mlx_audio") is not None
            ),
            path=(
                "Python package"
                if system.is_apple_silicon and importlib.util.find_spec("mlx_audio") is not None
                else None
            ),
            install_hint=(
                "Install localflow-gateway[apple]"
                if system.is_apple_silicon
                else "Available only on Apple-silicon Macs"
            ),
        ),
        DependencyStatus(
            name="WhisperKit CLI",
            available=system.whisperkit_cli_path is not None,
            path=system.whisperkit_cli_path,
            install_hint=(
                "brew install whisperkit-cli" if is_mac else "Available only on Apple platforms"
            ),
        ),
        DependencyStatus(
            name="Handy app",
            available=system.handy_installed,
            path=str(settings.handy_binary) if system.handy_installed else None,
            install_hint=("https://handy.computer" if is_mac else "Available only on macOS"),
        ),
        DependencyStatus(
            name="VocaMac app",
            available=system.vocamac_installed,
            path=str(settings.vocamac_app) if system.vocamac_installed else None,
            install_hint=(
                "https://github.com/jatinkrmalik/vocamac"
                if system.is_apple_silicon
                else "Available only on Apple silicon Macs"
            ),
        ),
    ]
    readiness_details = await ctx.readiness.details()
    state = readiness_details.health
    metrics = ctx.service.metrics.snapshot()
    return AdminStatusResponse(
        version=VERSION,
        engine=EngineStatus(id=engine_id(ctx), name=state.name, ready=state.ready),
        system=SystemStatus(
            os=f"{system.os_name} {system.os_version}",
            arch=system.arch,
            chip=system.chip,
            ram_gb=system.ram_gb,
            is_apple_silicon=system.is_apple_silicon,
            logical_cpus=system.logical_cpus,
            effective_cpus=system.effective_cpus,
            containerized=system.containerized,
            accelerators=list(system.accelerators),
            cpu_features=list(system.cpu_features),
        ),
        dependencies=dependencies,
        paths=PathStatus(
            data_dir=str(settings.data_dir),
            models_dir=str(ctx.manager.models_dir),
            config_file=str(ctx.config_path),
            token_file=TOKEN_FILE_HINT,
        ),
        bind_host=settings.bind_host,
        port=settings.port,
        setup=SetupChecklist(
            token_configured=True,
            ffmpeg_available=system.ffmpeg_path is not None,
            engine_binary_available=any(dependency.available for dependency in dependencies[1:]),
            model_installed=bool(ctx.manager.installed())
            or (ctx.engine_manager is not None and state.ready),
            engine_ready=state.ready,
        ),
        metrics=metrics_status(metrics),
        readiness=ReadinessStatus(
            probe_age_seconds=round(readiness_details.checked_age_seconds, 3),
            warmup_state=readiness_details.warmup_state,
            warmed_bytes=readiness_details.warmed_bytes,
        ),
    )


def model_entries(ctx: GatewayContext) -> list[AdminModelEntry]:
    settings = ctx.settings
    system = detect_system(
        whisper_binary=settings.whisper_binary,
        whisperkit_binary=settings.whisperkit_binary,
        handy_binary=settings.handy_binary,
        vocamac_app=settings.vocamac_app,
    )
    recommended = recommended_ids(system)
    installed = {model.id: model for model in ctx.manager.installed()}
    active_path = active_model_path(ctx)
    entries: list[AdminModelEntry] = []
    visible_catalog = (
        model
        for model in ctx.manager.catalog
        if (model.engine != "whisperkit" or system.is_apple_silicon)
        and (not model.apple_silicon_only or system.is_apple_silicon)
    )
    for model in visible_catalog:
        download = ctx.manager.download_state(model.id)
        installed_model = installed.get(model.id)
        state: Literal["installed", "downloading", "not_installed"] = "not_installed"
        progress: float | None = None
        error: str | None = None
        if download is not None and download.status == "downloading":
            state = "downloading"
            if download.total_bytes:
                progress = round(download.downloaded_bytes / download.total_bytes, 4)
        elif installed_model is not None:
            state = "installed"
        elif download is not None and download.status == "failed":
            error = download.error
        entries.append(
            AdminModelEntry(
                id=model.id,
                engine=model.engine,
                label=model.label,
                size_bytes=(installed_model.size_bytes if installed_model else model.size_bytes),
                languages=model.languages,
                quality=model.quality,
                family=model.family,
                description=model.description,
                source=model.source,
                supports_streaming=model.supports_streaming,
                license_name=model.license_name,
                commercial_use=model.commercial_use,
                detects_language_automatically=model.detects_language_automatically,
                language_names=language_names(model.language_codes),
                language_codes=list(model.language_codes),
                state=state,
                active=bool(installed_model and installed_model.path == active_path),
                recommended=model.id in recommended,
                progress=progress,
                downloaded_bytes=download.downloaded_bytes if download else None,
                total_bytes=(download.total_bytes if download else None),
                error=error,
            )
        )
    for custom in ctx.manager.installed():
        if custom.id.startswith("custom:"):
            entries.append(
                AdminModelEntry(
                    id=custom.id,
                    engine=custom.engine,
                    label=f"Custom: {custom.key}",
                    size_bytes=custom.size_bytes,
                    languages="Unknown",
                    quality="Custom",
                    family="Custom Whisper",
                    description="User-provided local model.",
                    source="Local file",
                    state="installed",
                    active=custom.path == active_path,
                    recommended=False,
                )
            )
    return entries


def filtered_model_entries(
    ctx: GatewayContext, installed_only: bool, language: str
) -> list[AdminModelEntry]:
    entries = model_entries(ctx)
    if installed_only:
        entries = [entry for entry in entries if entry.state == "installed"]
    if language:
        entries = [entry for entry in entries if model_covers(entry, language)]
    return entries


def token_entries(ctx: GatewayContext) -> list[DeviceTokenEntry]:
    entries = [
        DeviceTokenEntry(
            id=BOOTSTRAP_TOKEN_ID,
            label="Bootstrap token (LOCALFLOW_TOKEN / token file)",
            created_at=None,
            revocable=False,
        )
    ]
    entries.extend(
        DeviceTokenEntry(
            id=token.id, label=token.label, created_at=token.created_at, revocable=True
        )
        for token in ctx.token_store.all()
    )
    return entries


def config_response(ctx: GatewayContext) -> ConfigResponse:
    engine_manager = ctx.engine_manager
    runtime_config = engine_manager.runtime_config if engine_manager is not None else None
    return ConfigResponse(
        engine=runtime_config.engine if runtime_config is not None else "custom",
        available_engines=available_engines(ctx),
        whisper_model=(runtime_config.whisper_model if runtime_config else None),
        whisperkit_model=(runtime_config.whisperkit_model if runtime_config else None),
        faster_whisper_model=(runtime_config.faster_whisper_model if runtime_config else None),
        moonshine_model=(runtime_config.moonshine_model if runtime_config else "moonshine:en"),
        moonshine_language=(runtime_config.moonshine_language if runtime_config else "en"),
        sherpa_model=(runtime_config.sherpa_model if runtime_config else None),
        mlx_audio_model=(runtime_config.mlx_audio_model if runtime_config else None),
        compute_device=(runtime_config.compute_device if runtime_config else "auto"),
        compute_type=(runtime_config.compute_type if runtime_config else "auto"),
        cpu_threads=(runtime_config.cpu_threads if runtime_config else 0),
    )
