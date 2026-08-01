from __future__ import annotations

import asyncio
import hmac
import importlib.util
import json
import sys
import threading
import time
from array import array
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager, suppress
from pathlib import Path
from typing import Any, Literal
from uuid import UUID

from fastapi import (
    Depends,
    FastAPI,
    Form,
    Header,
    Query,
    Request,
    Response,
    WebSocket,
    WebSocketDisconnect,
)
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from app.audio import (
    ALLOWED_AUDIO_TYPES,
    FFmpegNormalizer,
    atomic_upload_path,
    complete_atomic_upload,
)
from app.catalog import recommended_ids
from app.config import Settings
from app.engines import (
    EngineManager,
    EngineProvider,
    StaticEngineProvider,
    build_engine,
    close_engine,
)
from app.errors import APIProblem
from app.fragments import (
    engine_pill_fragment,
    engine_pill_oob,
    engine_update_fragment,
    models_fragment,
    models_list_fragment,
    operations_fragment,
    overview_fragment,
    settings_fragment,
    test_fragment,
)
from app.model_manager import (
    DownloadInProgressError,
    ModelManager,
    UnknownModelError,
)
from app.models.base import AudioNormalizer, TranscriptionEngine
from app.models.moonshine import MoonshineEngine
from app.readiness import ReadinessMonitor
from app.runtime_config import RuntimeConfig
from app.schemas import (
    AdminModelEntry,
    AdminStatusResponse,
    ConfigResponse,
    ConfigUpdateRequest,
    CreateSessionRequest,
    CustomDownloadRequest,
    DeleteResponse,
    DependencyStatus,
    DownloadResponse,
    EngineStatus,
    ErrorDetail,
    ErrorEnvelope,
    HealthResponse,
    LivenessResponse,
    ModelResponse,
    OperationalMetricsStatus,
    PathStatus,
    ReadinessResponse,
    ReadinessStatus,
    SelectModelResponse,
    SessionResponse,
    SetupChecklist,
    SystemStatus,
    TestTranscriptionResponse,
)
from app.service import TranscriptionService
from app.storage import SessionRepository, StoredSession
from app.system import detect_system
from app.text_styles import apply_writing_style

VERSION = "0.2.0"
WEBUI_DIR = Path(__file__).parent / "webui"
TOKEN_FILE_HINT = "~/.config/localflow/token"


def create_app(
    settings: Settings | None = None,
    *,
    engine: TranscriptionEngine | None = None,
    normalizer: AudioNormalizer | None = None,
    model_manager: ModelManager | None = None,
    runtime_config: RuntimeConfig | None = None,
) -> FastAPI:
    configured = settings or Settings.from_env()
    repository = SessionRepository(configured.data_dir / "sessions.sqlite3")
    repository.initialize()
    manager = model_manager or ModelManager(configured.resolved_models_dir())
    config_path = configured.config_path
    if engine is not None:
        engine_provider: EngineProvider = StaticEngineProvider(engine)
        engine_manager: EngineManager | None = None
    else:
        engine_manager = EngineManager(
            configured,
            runtime_config or RuntimeConfig.load(config_path),
            config_path,
            manager,
        )
        engine_provider = engine_manager
    service = TranscriptionService(
        configured,
        repository,
        engine_provider,
        normalizer or FFmpegNormalizer(),
    )
    readiness = ReadinessMonitor(engine_provider)

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        service.cleanup_expired()
        warmup_task = asyncio.create_task(readiness.warmup())
        app.state.warmup_task = warmup_task
        try:
            yield
        finally:
            if not warmup_task.done():
                warmup_task.cancel()
                with suppress(asyncio.CancelledError):
                    await warmup_task
            await asyncio.to_thread(close_engine, engine_provider.current())

    app = FastAPI(
        title="Local Flow Gateway",
        version=VERSION,
        docs_url=None,
        redoc_url=None,
        lifespan=lifespan,
    )
    app.state.settings = configured
    app.state.service = service
    app.state.model_manager = manager
    app.state.metrics = service.metrics
    app.state.readiness = readiness

    @app.middleware("http")
    async def add_browser_security_headers(
        request: Request,
        call_next: Callable[[Request], Awaitable[Response]],
    ) -> Response:
        response = await call_next(request)
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Permissions-Policy"] = "microphone=(self)"
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
            "img-src 'self' data:; connect-src 'self'; media-src 'self' blob:; "
            "object-src 'none'; base-uri 'none'; frame-ancestors 'none'; "
            "form-action 'self'"
        )
        if request.url.path == "/" or request.url.path.startswith(("/ui/", "/v1/")):
            response.headers["Cache-Control"] = "no-store"
        return response

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

    def token_is_valid(authorization: str | None) -> bool:
        prefix = "Bearer "
        supplied = (
            authorization[len(prefix) :]
            if authorization and authorization.startswith(prefix)
            else ""
        )
        return hmac.compare_digest(supplied, configured.token)

    # ---------------------------------------------------------------- WebUI

    @app.get("/", include_in_schema=False)
    async def webui_index() -> FileResponse:
        return FileResponse(WEBUI_DIR / "index.html")

    if WEBUI_DIR.is_dir():
        app.mount("/assets", StaticFiles(directory=WEBUI_DIR), name="webui-assets")

    # -------------------------------------------------------------- iOS API

    @app.get("/health", response_model=HealthResponse)
    async def health() -> HealthResponse:
        state = await readiness.probe()
        return HealthResponse(
            engine_ready=state.ready,
            engine=state.name,
            streaming_supported=(
                state.ready and isinstance(engine_provider.current(), MoonshineEngine)
            ),
        )

    @app.get("/health/live", response_model=LivenessResponse)
    async def liveness() -> LivenessResponse:
        return LivenessResponse(uptime_seconds=service.metrics.snapshot().uptime_seconds)

    @app.get("/health/ready", response_model=ReadinessResponse)
    async def ready(response: Response) -> ReadinessResponse:
        details = await readiness.details()
        if not details.health.ready:
            response.status_code = 503
        return ReadinessResponse(
            status="ready" if details.health.ready else "not_ready",
            engine_ready=details.health.ready,
            engine=details.health.name,
            probe_age_seconds=round(details.checked_age_seconds, 3),
            warmup_state=details.warmup_state,
        )

    @app.get(
        "/v1/models",
        response_model=list[ModelResponse],
        dependencies=[Depends(require_token)],
    )
    async def models() -> list[ModelResponse]:
        state = await readiness.probe()
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

    @app.websocket("/v1/stream")
    async def stream_transcription(websocket: WebSocket) -> None:
        """Experimental float32 PCM stream for a selected Moonshine engine."""
        if not token_is_valid(websocket.headers.get("authorization")):
            await websocket.close(code=4401, reason="Unauthorized")
            return
        selected_engine = engine_provider.current()
        if not isinstance(selected_engine, MoonshineEngine):
            selected_health = await selected_engine.health()
            await websocket.accept()
            await websocket.send_json(
                {
                    "type": "unsupported",
                    "reason": "active_engine",
                    "engine": selected_health.name,
                }
            )
            await websocket.close(code=4409, reason="Active engine does not support streaming")
            return
        selected_health = await selected_engine.health()
        if not selected_health.ready:
            await websocket.accept()
            await websocket.send_json(
                {
                    "type": "unavailable",
                    "reason": "engine_not_ready",
                    "engine": selected_health.name,
                }
            )
            await websocket.close(code=4410, reason="Streaming engine is not ready")
            return
        await websocket.accept()
        stream: Any | None = None
        lines: dict[int, str] = {}
        lines_lock = threading.Lock()
        sample_rate = 0
        style = "casual"
        received_samples = 0
        try:
            start = await websocket.receive_json()
            if start.get("type") != "start":
                raise ValueError("The first stream message must be start.")
            sample_rate = int(start.get("sample_rate", 0))
            if not 8_000 <= sample_rate <= 96_000:
                raise ValueError("Sample rate must be between 8000 and 96000 Hz.")
            style = str(start.get("style", "casual"))
            if style not in {"raw", "clean", "formal", "casual", "very_casual", "excited"}:
                raise ValueError("Unsupported writing style.")
            async with selected_engine.streaming_lock:
                stream = await selected_engine.create_stream()

                def receive_event(event: object) -> None:
                    line = getattr(event, "line", None)
                    text_value = getattr(line, "text", "") if line is not None else ""
                    line_id = getattr(line, "line_id", None) if line is not None else None
                    if isinstance(line_id, int) and text_value:
                        with lines_lock:
                            lines[line_id] = str(text_value).strip()

                await asyncio.to_thread(stream.add_listener, receive_event)
                await websocket.send_json({"type": "ready", "engine": "moonshine"})
                while True:
                    message = await websocket.receive()
                    if message.get("type") == "websocket.disconnect":
                        break
                    chunk = message.get("bytes")
                    if chunk is not None:
                        if len(chunk) % 4:
                            raise ValueError("PCM chunks must contain float32 samples.")
                        samples = array("f")
                        samples.frombytes(chunk)
                        if sys.byteorder != "little":
                            samples.byteswap()
                        received_samples += len(samples)
                        if received_samples > sample_rate * configured.maximum_duration_seconds:
                            raise ValueError("The stream exceeds the recording duration limit.")
                        await asyncio.to_thread(stream.add_audio, samples.tolist(), sample_rate)
                        with lines_lock:
                            partial = _joined_stream_lines(lines)
                        if partial:
                            await websocket.send_json({"type": "partial", "transcript": partial})
                        continue
                    text_message = message.get("text")
                    if text_message:
                        command = json.loads(text_message)
                        if command.get("type") == "finish":
                            final_result = await asyncio.to_thread(stream.stop)
                            with lines_lock:
                                for line in getattr(final_result, "lines", []) or []:
                                    if getattr(line, "text", ""):
                                        lines[int(line.line_id)] = str(line.text).strip()
                                transcript = apply_writing_style(_joined_stream_lines(lines), style)
                            if not transcript:
                                raise ValueError("Moonshine returned an empty transcript.")
                            await websocket.send_json(
                                {"type": "complete", "transcript": transcript}
                            )
                            await websocket.close(code=1000)
                            return
        except WebSocketDisconnect:
            pass
        except Exception as error:  # noqa: BLE001 - sanitized protocol error
            with suppress(RuntimeError):
                await websocket.send_json(
                    {"type": "error", "message": str(error)[-200:] or "Streaming failed."}
                )
                await websocket.close(code=1011)
        finally:
            if stream is not None:
                with suppress(Exception):
                    await asyncio.to_thread(stream.close)

    # ------------------------------------------------------------ admin API

    def _engine_id() -> str:
        if engine_manager is not None:
            return engine_manager.runtime_config.engine
        return "custom"

    def _available_engines() -> list[str]:
        if engine_manager is None:
            return ["custom"]
        system = detect_system(
            whisper_binary=configured.whisper_binary,
            whisperkit_binary=configured.whisperkit_binary,
            handy_binary=configured.handy_binary,
        )
        engines = ["auto", "faster-whisper", "moonshine", "whisper.cpp"]
        if system.os_name == "Darwin":
            engines.extend(["handy", "whisperkit"])
        return engines

    async def _status_payload() -> AdminStatusResponse:
        system = detect_system(
            whisper_binary=configured.whisper_binary,
            whisperkit_binary=configured.whisperkit_binary,
            handy_binary=configured.handy_binary,
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
                path=str(configured.handy_binary) if system.handy_installed else None,
                install_hint=("https://handy.computer" if is_mac else "Available only on macOS"),
            ),
        ]
        readiness_details = await readiness.details()
        state = readiness_details.health
        metrics = service.metrics.snapshot()
        return AdminStatusResponse(
            version=VERSION,
            engine=EngineStatus(id=_engine_id(), name=state.name, ready=state.ready),
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
                data_dir=str(configured.data_dir),
                models_dir=str(manager.models_dir),
                config_file=str(config_path),
                token_file=TOKEN_FILE_HINT,
            ),
            bind_host=configured.bind_host,
            port=configured.port,
            setup=SetupChecklist(
                token_configured=True,
                ffmpeg_available=system.ffmpeg_path is not None,
                engine_binary_available=any(
                    dependency.available for dependency in dependencies[1:]
                ),
                model_installed=bool(manager.installed())
                or (engine_manager is not None and state.ready),
                engine_ready=state.ready,
            ),
            metrics=_metrics_status(metrics),
            readiness=ReadinessStatus(
                probe_age_seconds=round(readiness_details.checked_age_seconds, 3),
                warmup_state=readiness_details.warmup_state,
                warmed_bytes=readiness_details.warmed_bytes,
            ),
        )

    def _model_entries() -> list[AdminModelEntry]:
        system = detect_system(
            whisper_binary=configured.whisper_binary,
            whisperkit_binary=configured.whisperkit_binary,
            handy_binary=configured.handy_binary,
        )
        recommended = recommended_ids(system)
        installed = {model.id: model for model in manager.installed()}
        active_path = _active_model_path()
        entries: list[AdminModelEntry] = []
        visible_catalog = (
            model
            for model in manager.catalog
            if model.engine != "whisperkit" or system.is_apple_silicon
        )
        for model in visible_catalog:
            download = manager.download_state(model.id)
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
                    size_bytes=(
                        installed_model.size_bytes if installed_model else model.size_bytes
                    ),
                    languages=model.languages,
                    quality=model.quality,
                    family=model.family,
                    description=model.description,
                    source=model.source,
                    state=state,
                    active=bool(installed_model and installed_model.path == active_path),
                    recommended=model.id in recommended,
                    progress=progress,
                    downloaded_bytes=download.downloaded_bytes if download else None,
                    total_bytes=(download.total_bytes if download else None),
                    error=error,
                )
            )
        for custom in manager.installed():
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

    @app.get(
        "/v1/admin/status",
        response_model=AdminStatusResponse,
        dependencies=[Depends(require_token)],
    )
    async def get_admin_status() -> AdminStatusResponse:
        return await _status_payload()

    @app.get(
        "/v1/admin/models",
        response_model=list[AdminModelEntry],
        dependencies=[Depends(require_token)],
    )
    async def get_admin_models() -> list[AdminModelEntry]:
        return _model_entries()

    def _active_model_path() -> Path | None:
        if engine_manager is None:
            return None
        config = engine_manager.runtime_config
        if config.whisper_model:
            return Path(config.whisper_model)
        if config.whisperkit_model:
            return Path(config.whisperkit_model)
        if config.faster_whisper_model:
            return Path(config.faster_whisper_model)
        if config.engine == "moonshine":
            return manager.installed_path(f"moonshine:{config.moonshine_language}")
        return None

    @app.post(
        "/v1/admin/models/{model_id}/download",
        response_model=DownloadResponse,
        dependencies=[Depends(require_token)],
    )
    async def start_model_download(model_id: str) -> DownloadResponse:
        try:
            state = manager.start_download(model_id)
        except UnknownModelError as error:
            raise APIProblem(404, "unknown_model", "This model is not in the catalog.") from error
        except DownloadInProgressError as error:
            raise APIProblem(
                409, "download_in_progress", "This model is already downloading."
            ) from error
        return DownloadResponse(model_id=model_id, status=state.status)

    @app.post(
        "/v1/admin/models/custom",
        response_model=DownloadResponse,
        dependencies=[Depends(require_token)],
    )
    async def start_custom_download(body: CustomDownloadRequest) -> DownloadResponse:
        try:
            state = manager.start_custom_download(body.url)
        except ValueError as error:
            raise APIProblem(422, "invalid_model_url", str(error)) from error
        except DownloadInProgressError as error:
            raise APIProblem(409, "download_in_progress", str(error)) from error
        return DownloadResponse(model_id=state.model_id, status=state.status)

    @app.post(
        "/v1/admin/models/{model_id}/cancel",
        response_model=DownloadResponse,
        dependencies=[Depends(require_token)],
    )
    async def cancel_model_download(model_id: str) -> DownloadResponse:
        if not manager.cancel_download(model_id):
            raise APIProblem(409, "download_not_active", "This model is not currently downloading.")
        return DownloadResponse(model_id=model_id, status="cancelling")

    @app.delete(
        "/v1/admin/models/{model_id}",
        response_model=DeleteResponse,
        dependencies=[Depends(require_token)],
    )
    async def delete_model(model_id: str, response: Response) -> DeleteResponse:
        try:
            if engine_manager is not None:
                engine_manager.forget_if_active(model_id)
            deleted = manager.delete(model_id)
        except DownloadInProgressError as error:
            raise APIProblem(
                409, "download_in_progress", "Cancel the download before deleting."
            ) from error
        if not deleted:
            response.status_code = 404
        return DeleteResponse(deleted=deleted)

    @app.post(
        "/v1/admin/models/{model_id}/select",
        response_model=SelectModelResponse,
        dependencies=[Depends(require_token)],
    )
    async def select_model(model_id: str) -> SelectModelResponse:
        if engine_manager is None:
            raise APIProblem(
                409, "engine_locked", "The engine was fixed at startup and cannot switch."
            )
        try:
            engine_manager.select_model(model_id)
        except KeyError as error:
            raise APIProblem(
                404, "model_not_installed", "Download this model before selecting it."
            ) from error
        await readiness.warmup()
        state = await readiness.probe()
        return SelectModelResponse(
            engine=EngineStatus(
                id=engine_manager.runtime_config.engine, name=state.name, ready=state.ready
            )
        )

    @app.get(
        "/v1/admin/config",
        response_model=ConfigResponse,
        dependencies=[Depends(require_token)],
    )
    async def get_config() -> ConfigResponse:
        engine_value = (
            engine_manager.runtime_config.engine if engine_manager is not None else "custom"
        )
        return ConfigResponse(
            engine=engine_value,
            available_engines=_available_engines(),
            whisper_model=(engine_manager.runtime_config.whisper_model if engine_manager else None),
            whisperkit_model=(
                engine_manager.runtime_config.whisperkit_model if engine_manager else None
            ),
            faster_whisper_model=(
                engine_manager.runtime_config.faster_whisper_model if engine_manager else None
            ),
            moonshine_language=(
                engine_manager.runtime_config.moonshine_language if engine_manager else "en"
            ),
            compute_device=(
                engine_manager.runtime_config.compute_device if engine_manager else "auto"
            ),
            compute_type=(engine_manager.runtime_config.compute_type if engine_manager else "auto"),
            cpu_threads=(engine_manager.runtime_config.cpu_threads if engine_manager else 0),
        )

    @app.put(
        "/v1/admin/config",
        response_model=SelectModelResponse,
        dependencies=[Depends(require_token)],
    )
    async def update_config(body: ConfigUpdateRequest) -> SelectModelResponse:
        if engine_manager is None:
            raise APIProblem(
                409, "engine_locked", "The engine was fixed at startup and cannot switch."
            )
        engine_manager.configure(
            body.engine,
            body.compute_device,
            body.compute_type,
            body.cpu_threads,
        )
        await readiness.warmup()
        state = await readiness.probe()
        return SelectModelResponse(
            engine=EngineStatus(id=body.engine, name=state.name, ready=state.ready)
        )

    @app.post(
        "/v1/admin/test-transcription",
        response_model=TestTranscriptionResponse,
        dependencies=[Depends(require_token)],
    )
    async def test_transcription(
        request: Request,
        language: str = Query(default="auto", pattern=r"^[A-Za-z-]+$|^auto$"),
        content_type: str | None = Header(default=None),
        content_length: int | None = Header(default=None),
    ) -> TestTranscriptionResponse:
        normalized_type = (content_type or "").split(";", maxsplit=1)[0].lower()
        suffix = ALLOWED_AUDIO_TYPES.get(normalized_type)
        if suffix is None:
            raise APIProblem(415, "unsupported_audio_type", "This audio type is not supported.")
        if content_length is not None and content_length > configured.maximum_upload_bytes:
            raise APIProblem(413, "audio_too_large", "The recording exceeds the upload limit.")
        upload_dir = configured.data_dir / "test-uploads"
        temporary, final = atomic_upload_path(upload_dir, f"test-{int(time.time() * 1000)}", suffix)
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
        try:
            result = await service.transcribe_adhoc(final, language)
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

    # ------------------------------------------------- WebUI partials (HTMX)

    def _html(content: str) -> HTMLResponse:
        return HTMLResponse(content)

    def _models_list_html() -> HTMLResponse:
        return _html(models_list_fragment(_model_entries()))

    @app.get(
        "/ui/partials/overview",
        response_class=HTMLResponse,
        dependencies=[Depends(require_token)],
    )
    async def ui_overview() -> HTMLResponse:
        return _html(overview_fragment(await _status_payload()))

    @app.get(
        "/ui/partials/operations",
        response_class=HTMLResponse,
        dependencies=[Depends(require_token)],
    )
    async def ui_operations() -> HTMLResponse:
        metrics = service.metrics.snapshot()
        readiness_details = await readiness.details()
        return _html(
            operations_fragment(
                _metrics_status(metrics),
                ReadinessStatus(
                    probe_age_seconds=round(readiness_details.checked_age_seconds, 3),
                    warmup_state=readiness_details.warmup_state,
                    warmed_bytes=readiness_details.warmed_bytes,
                ),
            )
        )

    @app.get(
        "/ui/partials/engine-pill",
        response_class=HTMLResponse,
        dependencies=[Depends(require_token)],
    )
    async def ui_engine_pill() -> HTMLResponse:
        state = await readiness.probe()
        return _html(
            engine_pill_fragment(EngineStatus(id=_engine_id(), name=state.name, ready=state.ready))
        )

    @app.get(
        "/ui/partials/models",
        response_class=HTMLResponse,
        dependencies=[Depends(require_token)],
    )
    async def ui_models() -> HTMLResponse:
        return _html(models_fragment(_model_entries()))

    @app.get(
        "/ui/partials/models-list",
        response_class=HTMLResponse,
        dependencies=[Depends(require_token)],
    )
    async def ui_models_list() -> HTMLResponse:
        return _models_list_html()

    @app.post(
        "/ui/partials/models/{model_id}/download",
        response_class=HTMLResponse,
        dependencies=[Depends(require_token)],
    )
    async def ui_start_download(model_id: str) -> HTMLResponse:
        try:
            manager.start_download(model_id)
        except UnknownModelError as error:
            raise APIProblem(404, "unknown_model", "This model is not in the catalog.") from error
        except DownloadInProgressError as error:
            raise APIProblem(
                409, "download_in_progress", "This model is already downloading."
            ) from error
        return _models_list_html()

    @app.post(
        "/ui/partials/models/custom",
        response_class=HTMLResponse,
        dependencies=[Depends(require_token)],
    )
    async def ui_custom_download(url: str = Form(...)) -> HTMLResponse:
        try:
            manager.start_custom_download(url)
        except ValueError as error:
            raise APIProblem(422, "invalid_model_url", str(error)) from error
        except DownloadInProgressError as error:
            raise APIProblem(409, "download_in_progress", str(error)) from error
        return _models_list_html()

    @app.post(
        "/ui/partials/models/{model_id}/cancel",
        response_class=HTMLResponse,
        dependencies=[Depends(require_token)],
    )
    async def ui_cancel_download(model_id: str) -> HTMLResponse:
        manager.cancel_download(model_id)
        return _models_list_html()

    @app.delete(
        "/ui/partials/models/{model_id}",
        response_class=HTMLResponse,
        dependencies=[Depends(require_token)],
    )
    async def ui_delete_model(model_id: str) -> HTMLResponse:
        try:
            if engine_manager is not None:
                engine_manager.forget_if_active(model_id)
            manager.delete(model_id)
        except DownloadInProgressError as error:
            raise APIProblem(
                409, "download_in_progress", "Cancel the download before deleting."
            ) from error
        return _models_list_html()

    @app.post(
        "/ui/partials/models/{model_id}/select",
        response_class=HTMLResponse,
        dependencies=[Depends(require_token)],
    )
    async def ui_select_model(model_id: str) -> HTMLResponse:
        if engine_manager is None:
            raise APIProblem(
                409, "engine_locked", "The engine was fixed at startup and cannot switch."
            )
        try:
            engine_manager.select_model(model_id)
        except KeyError as error:
            raise APIProblem(
                404, "model_not_installed", "Download this model before selecting it."
            ) from error
        await readiness.warmup()
        state = await readiness.probe()
        return _html(
            models_list_fragment(_model_entries())
            + engine_pill_oob(
                EngineStatus(
                    id=engine_manager.runtime_config.engine, name=state.name, ready=state.ready
                )
            )
        )

    @app.get(
        "/ui/partials/settings",
        response_class=HTMLResponse,
        dependencies=[Depends(require_token)],
    )
    async def ui_settings() -> HTMLResponse:
        engine_value = (
            engine_manager.runtime_config.engine if engine_manager is not None else "custom"
        )
        config = ConfigResponse(
            engine=engine_value,
            available_engines=_available_engines(),
            compute_device=(
                engine_manager.runtime_config.compute_device if engine_manager else "auto"
            ),
            compute_type=(engine_manager.runtime_config.compute_type if engine_manager else "auto"),
            cpu_threads=(engine_manager.runtime_config.cpu_threads if engine_manager else 0),
        )
        paths = [
            ("Data directory", str(configured.data_dir)),
            ("Models directory", str(manager.models_dir)),
            ("WebUI config file", str(config_path)),
            ("Token file", TOKEN_FILE_HINT),
        ]
        return _html(settings_fragment(config, paths, configured.bind_host, configured.port))

    @app.put(
        "/ui/partials/config",
        response_class=HTMLResponse,
        dependencies=[Depends(require_token)],
    )
    async def ui_update_config(
        engine: str = Form(...),
        compute_device: str = Form("auto"),
        compute_type: str = Form("auto"),
        cpu_threads: int = Form(0),
    ) -> HTMLResponse:
        if engine_manager is None:
            raise APIProblem(
                409, "engine_locked", "The engine was fixed at startup and cannot switch."
            )
        try:
            engine_manager.configure(engine, compute_device, compute_type, cpu_threads)
        except ValueError as error:
            raise APIProblem(422, "invalid_engine", str(error)) from error
        await readiness.warmup()
        state = await readiness.probe()
        return _html(
            engine_update_fragment(
                EngineStatus(id=engine, name=state.name, ready=state.ready),
                "Engine preference saved.",
            )
        )

    @app.get(
        "/ui/partials/test",
        response_class=HTMLResponse,
        dependencies=[Depends(require_token)],
    )
    async def ui_test() -> HTMLResponse:
        return _html(test_fragment(configured.maximum_duration_seconds))

    return app


def select_engine(settings: Settings) -> TranscriptionEngine:
    """Resolve an engine purely from environment settings (CLI usage)."""
    if settings.engine not in {
        "auto",
        "handy",
        "whisper.cpp",
        "whisperkit",
        "faster-whisper",
        "moonshine",
    }:
        raise RuntimeError("LOCALFLOW_ENGINE is not a supported engine.")
    manager = ModelManager(settings.resolved_models_dir())
    if settings.engine == "auto":
        from app.models.whisper_cpp import WhisperCppEngine

        if settings.handy_binary.is_file():
            from app.models.handy import HandyEngine

            return HandyEngine(
                settings.handy_binary,
                settings.handy_model,
                fallback_model=settings.handy_fallback_model,
            )
        return WhisperCppEngine(settings.whisper_binary, settings.whisper_model)
    return build_engine(settings, RuntimeConfig(engine=settings.engine), manager)


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


def _metrics_status(metrics: object) -> OperationalMetricsStatus:
    pipeline = metrics.last_pipeline  # type: ignore[attr-defined]
    return OperationalMetricsStatus(
        uptime_seconds=metrics.uptime_seconds,  # type: ignore[attr-defined]
        queue_depth=metrics.queue_depth,  # type: ignore[attr-defined]
        active_transcriptions=metrics.active_transcriptions,  # type: ignore[attr-defined]
        concurrency_limit=metrics.concurrency_limit,  # type: ignore[attr-defined]
        successful_transcriptions=metrics.successful_transcriptions,  # type: ignore[attr-defined]
        failed_transcriptions=metrics.failed_transcriptions,  # type: ignore[attr-defined]
        rejected_transcriptions=metrics.rejected_transcriptions,  # type: ignore[attr-defined]
        average_latency_ms=metrics.average_latency_ms,  # type: ignore[attr-defined]
        last_latency_ms=metrics.last_latency_ms,  # type: ignore[attr-defined]
        normalization_ms=pipeline.normalization_ms if pipeline else None,
        model_load_ms=pipeline.model_load_ms if pipeline else None,
        inference_ms=pipeline.inference_ms if pipeline else None,
        audio_duration_ms=pipeline.audio_duration_ms if pipeline else None,
        real_time_factor=pipeline.real_time_factor if pipeline else None,
        peak_memory_mb=pipeline.peak_memory_mb if pipeline else None,
    )


def _joined_stream_lines(lines: dict[int, str]) -> str:
    return " ".join(lines[key] for key in sorted(lines) if lines[key]).strip()
