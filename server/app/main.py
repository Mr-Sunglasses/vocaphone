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
from app.diagnostics import build_diagnostics_bundle
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
    pairing_fragment,
    settings_fragment,
    test_fragment,
    tokens_fragment,
)
from app.model_manager import (
    DownloadInProgressError,
    ModelManager,
    UnknownModelError,
)
from app.models.base import AudioNormalizer, StreamingEngine, TranscriptionEngine
from app.pairing import (
    decode_pairing_payload,
    discover_gateway_base_urls,
    encode_pairing_payload,
    is_ambient_lan_address,
    normalize_gateway_input,
    primary_gateway_base_url,
    qr_svg_for_payload,
)
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
    DeviceTokenCreateRequest,
    DeviceTokenCreateResponse,
    DeviceTokenEntry,
    DeviceTokenRevokeResponse,
    DiagnosticsBundle,
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
from app.system import detect_system, engine_runs_on
from app.text_styles import apply_writing_style
from app.tokens import TokenStore

VERSION = "0.2.0"
WEBUI_DIR = Path(__file__).parent / "webui"
TOKEN_FILE_HINT = "~/.config/localflow/token"
BOOTSTRAP_TOKEN_ID = "bootstrap"


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
    token_store = TokenStore(configured.data_dir / "device_tokens.json")
    config_path = configured.config_path
    if engine is not None:
        engine_provider: EngineProvider = StaticEngineProvider(engine)
        engine_manager: EngineManager | None = None
        pairing_config = RuntimeConfig()
    else:
        engine_manager = EngineManager(
            configured,
            runtime_config or RuntimeConfig.load(config_path),
            config_path,
            manager,
        )
        engine_provider = engine_manager
        pairing_config = engine_manager.runtime_config
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
        openapi_url="/openapi.json" if configured.debug else None,
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

    def _token_matches(supplied: str) -> bool:
        if hmac.compare_digest(supplied, configured.token):
            return True
        return token_store.matches(supplied)

    def require_token(authorization: str | None = Header(default=None)) -> None:
        prefix = "Bearer "
        supplied = (
            authorization[len(prefix) :]
            if authorization and authorization.startswith(prefix)
            else ""
        )
        if not _token_matches(supplied):
            raise APIProblem(401, "unauthorized", "A valid bearer token is required.")

    def token_is_valid(authorization: str | None) -> bool:
        prefix = "Bearer "
        supplied = (
            authorization[len(prefix) :]
            if authorization and authorization.startswith(prefix)
            else ""
        )
        return _token_matches(supplied)

    # ---------------------------------------------------------------- WebUI

    @app.get("/", include_in_schema=False)
    async def webui_index() -> FileResponse:
        return FileResponse(WEBUI_DIR / "index.html")

    if WEBUI_DIR.is_dir():
        app.mount("/assets", StaticFiles(directory=WEBUI_DIR), name="webui-assets")

    # ------------------------------------------------------------- API docs

    if configured.debug:

        @app.get("/docs", include_in_schema=False)
        async def api_docs() -> HTMLResponse:
            # Swagger UI's init call is loaded from an external, same-origin
            # script rather than inlined, because the CSP above sends
            # `script-src 'self'` with no `'unsafe-inline'`.
            favicon = (
                "data:image/svg+xml,&lt;svg xmlns='http://www.w3.org/2000/svg' "
                "viewBox='0 0 100 100'&gt;&lt;text y='.9em' "
                "font-size='90'&gt;&#127908;&lt;/text&gt;&lt;/svg&gt;"
            )
            return HTMLResponse(f"""<!doctype html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<link type="text/css" rel="stylesheet" href="/assets/swagger/swagger-ui.css">
<link rel="icon" href="{favicon}">
<title>{app.title} - API docs</title>
</head>
<body>
<div id="swagger-ui"></div>
<script src="/assets/swagger/swagger-ui-bundle.js"></script>
<script src="/assets/swagger/docs-init.js"></script>
</body>
</html>
""")

    # -------------------------------------------------------------- iOS API

    @app.get("/health", response_model=HealthResponse)
    async def health() -> HealthResponse:
        state = await readiness.probe()
        selected_engine = engine_provider.current()
        return HealthResponse(
            engine_ready=state.ready,
            engine=state.name,
            streaming_supported=(
                state.ready
                and isinstance(selected_engine, StreamingEngine)
                and selected_engine.supports_streaming
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
        """Experimental float32 PCM stream for a streaming-capable engine.

        Any engine exposing `supports_streaming` (True), `streaming_lock`, and
        `create_stream()` returning an object with `add_listener`/`add_audio`/
        `stop` works here — currently Moonshine and the sherpa-onnx streaming
        zipformer model.
        """
        if not token_is_valid(websocket.headers.get("authorization")):
            await websocket.close(code=4401, reason="Unauthorized")
            return
        selected_engine = engine_provider.current()
        if (
            not isinstance(selected_engine, StreamingEngine)
            or not selected_engine.supports_streaming
        ):
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
        language = "auto"
        received_samples = 0
        try:
            start = await websocket.receive_json()
            if start.get("type") != "start":
                raise ValueError("The first stream message must be start.")
            sample_rate = int(start.get("sample_rate", 0))
            if not 8_000 <= sample_rate <= 96_000:
                raise ValueError("Sample rate must be between 8000 and 96000 Hz.")
            language = str(start.get("language", "auto"))
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
                await websocket.send_json(
                    {"type": "ready", "engine": selected_health.name.split(":", 1)[0]}
                )
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
                                transcript = apply_writing_style(
                                    _joined_stream_lines(lines), style, language
                                )
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
            vocamac_app=configured.vocamac_app,
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

    async def _status_payload() -> AdminStatusResponse:
        system = detect_system(
            whisper_binary=configured.whisper_binary,
            whisperkit_binary=configured.whisperkit_binary,
            handy_binary=configured.handy_binary,
            vocamac_app=configured.vocamac_app,
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
                path=str(configured.handy_binary) if system.handy_installed else None,
                install_hint=("https://handy.computer" if is_mac else "Available only on macOS"),
            ),
            DependencyStatus(
                name="VocaMac app",
                available=system.vocamac_installed,
                path=str(configured.vocamac_app) if system.vocamac_installed else None,
                install_hint=(
                    "https://github.com/jatinkrmalik/vocamac"
                    if system.is_apple_silicon
                    else "Available only on Apple silicon Macs"
                ),
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
            vocamac_app=configured.vocamac_app,
        )
        recommended = recommended_ids(system)
        installed = {model.id: model for model in manager.installed()}
        active_path = _active_model_path()
        entries: list[AdminModelEntry] = []
        visible_catalog = (
            model
            for model in manager.catalog
            if (model.engine != "whisperkit" or system.is_apple_silicon)
            and (not model.apple_silicon_only or system.is_apple_silicon)
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
                    supports_streaming=model.supports_streaming,
                    license_name=model.license_name,
                    commercial_use=model.commercial_use,
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
        "/v1/admin/diagnostics",
        response_model=DiagnosticsBundle,
        dependencies=[Depends(require_token)],
    )
    async def get_admin_diagnostics(response: Response) -> DiagnosticsBundle:
        bundle = build_diagnostics_bundle(await _status_payload(), await get_config())
        filename = f"localflow-diagnostics-{bundle.generated_at:%Y%m%dT%H%M%SZ}.json"
        response.headers["Content-Disposition"] = f'attachment; filename="{filename}"'
        return bundle

    def _token_entries() -> list[DeviceTokenEntry]:
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
            for token in token_store.all()
        )
        return entries

    @app.get(
        "/v1/admin/tokens",
        response_model=list[DeviceTokenEntry],
        dependencies=[Depends(require_token)],
    )
    async def list_admin_tokens() -> list[DeviceTokenEntry]:
        return _token_entries()

    @app.post(
        "/v1/admin/tokens",
        response_model=DeviceTokenCreateResponse,
        dependencies=[Depends(require_token)],
    )
    async def create_admin_token(body: DeviceTokenCreateRequest) -> DeviceTokenCreateResponse:
        record, plaintext = token_store.create(body.label)
        return DeviceTokenCreateResponse(
            id=record.id, label=record.label, token=plaintext, created_at=record.created_at
        )

    @app.delete(
        "/v1/admin/tokens/{token_id}",
        response_model=DeviceTokenRevokeResponse,
        dependencies=[Depends(require_token)],
    )
    async def revoke_admin_token(token_id: str, response: Response) -> DeviceTokenRevokeResponse:
        if token_id == BOOTSTRAP_TOKEN_ID:
            raise APIProblem(
                409,
                "bootstrap_token_not_revocable",
                "Rotate LOCALFLOW_TOKEN or its token file instead of revoking it here.",
            )
        revoked = token_store.revoke(token_id)
        if not revoked:
            response.status_code = 404
        return DeviceTokenRevokeResponse(revoked=revoked)

    @app.post(
        "/v1/admin/tokens/{token_id}/rotate",
        response_model=DeviceTokenCreateResponse,
        dependencies=[Depends(require_token)],
    )
    async def rotate_admin_token(token_id: str) -> DeviceTokenCreateResponse:
        if token_id == BOOTSTRAP_TOKEN_ID:
            raise APIProblem(
                409,
                "bootstrap_token_not_rotatable",
                "Rotate LOCALFLOW_TOKEN or its token file instead of rotating it here.",
            )
        rotated = token_store.rotate(token_id)
        if rotated is None:
            raise APIProblem(404, "token_not_found", "This device token no longer exists.")
        record, plaintext = rotated
        return DeviceTokenCreateResponse(
            id=record.id, label=record.label, token=plaintext, created_at=record.created_at
        )

    @app.get(
        "/v1/admin/models",
        response_model=list[AdminModelEntry],
        dependencies=[Depends(require_token)],
    )
    async def get_admin_models(installed_only: bool = False) -> list[AdminModelEntry]:
        entries = _model_entries()
        if installed_only:
            entries = [entry for entry in entries if entry.state == "installed"]
        return entries

    def _active_model_path() -> Path | None:
        if engine_manager is None:
            return None
        config = engine_manager.runtime_config
        if config.engine == "moonshine":
            return manager.installed_path(config.moonshine_model)
        if config.engine == "sherpa-onnx" and config.sherpa_model:
            return manager.installed_path(config.sherpa_model)
        if config.engine == "mlx-audio" and config.mlx_audio_model:
            return manager.installed_path(config.mlx_audio_model)
        if config.whisper_model:
            return Path(config.whisper_model)
        if config.whisperkit_model:
            return Path(config.whisperkit_model)
        if config.faster_whisper_model:
            return Path(config.faster_whisper_model)
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
            moonshine_model=(
                engine_manager.runtime_config.moonshine_model if engine_manager else "moonshine:en"
            ),
            moonshine_language=(
                engine_manager.runtime_config.moonshine_language if engine_manager else "en"
            ),
            sherpa_model=(engine_manager.runtime_config.sherpa_model if engine_manager else None),
            mlx_audio_model=(
                engine_manager.runtime_config.mlx_audio_model if engine_manager else None
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
        try:
            engine_manager.configure(
                body.engine,
                body.compute_device,
                body.compute_type,
                body.cpu_threads,
            )
        except ValueError as error:
            raise APIProblem(422, "invalid_engine", str(error)) from error
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

    def _models_list_html(installed_only: bool = False) -> HTMLResponse:
        entries = _model_entries()
        if installed_only:
            entries = [entry for entry in entries if entry.state == "installed"]
        return _html(models_list_fragment(entries, installed_only))

    def _resolve_pairing_token(
        token_id: str | None,
    ) -> tuple[str, str, Literal["ok", "stale", "unknown"], str | None]:
        """Return (resolved_id, plaintext, status, requested_label).

        `stale` means the token still exists (see it under Settings) but this
        process never cached its plaintext — normally because it was created
        before the gateway last restarted. `unknown` means no such token
        exists at all (typically already revoked). Both fall back to the
        bootstrap token for the QR actually shown; only `stale` can be fixed
        by rotating the token to give it a fresh, displayable secret.
        """
        if token_id and token_id != BOOTSTRAP_TOKEN_ID:
            cached = token_store.cached_plaintext(token_id)
            if cached is not None:
                return token_id, cached, "ok", None
            existing = token_store.get(token_id)
            if existing is not None:
                return BOOTSTRAP_TOKEN_ID, configured.token, "stale", existing.label
            return BOOTSTRAP_TOKEN_ID, configured.token, "unknown", None
        return BOOTSTRAP_TOKEN_ID, configured.token, "ok", None

    def _pairing_token_options() -> list[tuple[str, str]]:
        cached_ids = {token.id for token in token_store.cached_entries()}
        options = [(BOOTSTRAP_TOKEN_ID, "Bootstrap token")]
        options.extend(
            (
                token.id,
                token.label if token.id in cached_ids else f"{token.label} (paired; no live QR)",
            )
            for token in reversed(token_store.all())
        )
        return options

    def _forget_stale_lan_addresses(discovered: list[str]) -> None:
        """Drop any remembered LAN/tailnet IP no longer part of fresh discovery.

        A bare LAN or Tailscale IP reflects whichever network the gateway was
        on when it was picked; keeping it around after switching Wi-Fi just
        clutters the address list and dropdown with a dead entry. Hostnames
        (MagicDNS names, custom domains) and public IPs are never touched —
        the user chose those deliberately and they aren't tied to one network.
        """
        if engine_manager is None:
            return
        changed = False
        if (
            pairing_config.pairing_url
            and pairing_config.pairing_url not in discovered
            and is_ambient_lan_address(pairing_config.pairing_url)
        ):
            pairing_config.pairing_url = None
            changed = True
        remaining = [
            url
            for url in pairing_config.pairing_urls
            if url in discovered or not is_ambient_lan_address(url)
        ]
        if len(remaining) != len(pairing_config.pairing_urls):
            pairing_config.pairing_urls = remaining
            changed = True
        if changed:
            pairing_config.save(config_path)

    def _pairing_html(
        selected_url: str | None = None, token_id: str | None = None, *, persist: bool = False
    ) -> str:
        discovered = discover_gateway_base_urls(configured.port)
        _forget_stale_lan_addresses(discovered)
        candidates = list(discovered)
        for saved in pairing_config.pairing_urls:
            if saved not in candidates:
                candidates.append(saved)
        selected: str | None
        if selected_url:
            try:
                selected = normalize_gateway_input(selected_url, configured.port)
            except ValueError:
                selected = pairing_config.pairing_url or primary_gateway_base_url(configured.port)
            else:
                if selected not in candidates:
                    candidates = [selected, *candidates]
                if persist and engine_manager is not None:
                    changed = pairing_config.pairing_url != selected
                    if selected not in discovered and selected not in pairing_config.pairing_urls:
                        pairing_config.pairing_urls.append(selected)
                        changed = True
                    if changed:
                        pairing_config.pairing_url = selected
                        pairing_config.save(config_path)
        else:
            selected = pairing_config.pairing_url or primary_gateway_base_url(configured.port)
            if selected and selected not in candidates:
                candidates = [selected, *candidates]
        resolved_token_id, token, token_status, requested_label = _resolve_pairing_token(token_id)
        redacted = (
            f"{token[:4]}…{token[-4:]} ({len(token)} characters)"
            if len(token) > 8
            else "•" * len(token)
        )
        qr_svg = ""
        if selected:
            qr_svg = qr_svg_for_payload(encode_pairing_payload(selected, token))
        return pairing_fragment(
            selected_url=selected,
            candidates=candidates,
            token_redacted=redacted,
            qr_svg=qr_svg,
            saved_urls=pairing_config.pairing_urls,
            token_options=_pairing_token_options(),
            selected_token_id=resolved_token_id,
            token_status=token_status,
            requested_token_id=token_id or "",
            requested_token_label=requested_label,
        )

    def _forget_pairing_url(url: str) -> str:
        try:
            normalized = normalize_gateway_input(url, configured.port)
        except ValueError as error:
            raise APIProblem(400, "invalid_pairing_url", str(error)) from error
        if engine_manager is not None and normalized in pairing_config.pairing_urls:
            pairing_config.pairing_urls.remove(normalized)
            if pairing_config.pairing_url == normalized:
                pairing_config.pairing_url = None
            pairing_config.save(config_path)
        return _pairing_html()

    def _resolve_pairing_url(url: str | None) -> str:
        candidates = discover_gateway_base_urls(configured.port)
        if url:
            try:
                return normalize_gateway_input(url, configured.port)
            except ValueError as error:
                raise APIProblem(400, "invalid_pairing_url", str(error)) from error
        if not candidates:
            raise APIProblem(
                503,
                "pairing_unavailable",
                "No phone-reachable gateway address was detected. "
                "Set LOCALFLOW_PUBLIC_URL and retry.",
            )
        return candidates[0]

    @app.get(
        "/v1/admin/pairing",
        dependencies=[Depends(require_token)],
    )
    async def get_pairing(
        url: str | None = Query(default=None), token_id: str | None = Query(default=None)
    ) -> dict[str, Any]:
        selected = _resolve_pairing_url(url)
        _, token, _, _ = _resolve_pairing_token(token_id)
        payload = encode_pairing_payload(selected, token)
        # Round-trip so clients and tests share one format.
        decoded = decode_pairing_payload(payload)
        return {
            "version": decoded.version,
            "url": decoded.url,
            "payload": payload,
            "candidates": discover_gateway_base_urls(configured.port),
        }

    @app.get(
        "/v1/admin/pairing/qr.svg",
        dependencies=[Depends(require_token)],
        response_class=Response,
    )
    async def get_pairing_qr(
        url: str | None = Query(default=None), token_id: str | None = Query(default=None)
    ) -> Response:
        selected = _resolve_pairing_url(url)
        _, token, _, _ = _resolve_pairing_token(token_id)
        payload = encode_pairing_payload(selected, token)
        svg = qr_svg_for_payload(payload)
        return Response(
            content=svg,
            media_type="image/svg+xml",
            headers={"Cache-Control": "no-store"},
        )

    @app.get(
        "/ui/partials/pairing",
        response_class=HTMLResponse,
        dependencies=[Depends(require_token)],
    )
    async def ui_pairing(
        url: str | None = Query(default=None), token_id: str | None = Query(default=None)
    ) -> HTMLResponse:
        return _html(_pairing_html(url, token_id, persist=True))

    @app.post(
        "/ui/partials/pairing/tokens",
        response_class=HTMLResponse,
        dependencies=[Depends(require_token)],
    )
    async def ui_create_pairing_token(
        label: str = Form(..., min_length=1, max_length=100), url: str | None = Form(default=None)
    ) -> HTMLResponse:
        record, _ = token_store.create(label)
        return _html(_pairing_html(url, record.id, persist=True))

    @app.post(
        "/ui/partials/pairing/tokens/{token_id}/rotate",
        response_class=HTMLResponse,
        dependencies=[Depends(require_token)],
    )
    async def ui_rotate_pairing_token(
        token_id: str, url: str | None = Form(default=None)
    ) -> HTMLResponse:
        rotated = token_store.rotate(token_id)
        resolved_id = rotated[0].id if rotated is not None else token_id
        return _html(_pairing_html(url, resolved_id, persist=True))

    @app.delete(
        "/ui/partials/pairing",
        response_class=HTMLResponse,
        dependencies=[Depends(require_token)],
    )
    async def ui_forget_pairing(url: str = Query(...)) -> HTMLResponse:
        return _html(_forget_pairing_url(url))

    @app.get(
        "/ui/partials/overview",
        response_class=HTMLResponse,
        dependencies=[Depends(require_token)],
    )
    async def ui_overview() -> HTMLResponse:
        return _html(overview_fragment(await _status_payload(), pairing_html=_pairing_html()))

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
    async def ui_models_list(installed_only: bool = False) -> HTMLResponse:
        return _models_list_html(installed_only)

    @app.post(
        "/ui/partials/models/{model_id}/download",
        response_class=HTMLResponse,
        dependencies=[Depends(require_token)],
    )
    async def ui_start_download(model_id: str, installed_only: bool = Form(False)) -> HTMLResponse:
        try:
            manager.start_download(model_id)
        except UnknownModelError as error:
            raise APIProblem(404, "unknown_model", "This model is not in the catalog.") from error
        except DownloadInProgressError as error:
            raise APIProblem(
                409, "download_in_progress", "This model is already downloading."
            ) from error
        return _models_list_html(installed_only)

    @app.post(
        "/ui/partials/models/custom",
        response_class=HTMLResponse,
        dependencies=[Depends(require_token)],
    )
    async def ui_custom_download(
        url: str = Form(...), installed_only: bool = Form(False)
    ) -> HTMLResponse:
        try:
            manager.start_custom_download(url)
        except ValueError as error:
            raise APIProblem(422, "invalid_model_url", str(error)) from error
        except DownloadInProgressError as error:
            raise APIProblem(409, "download_in_progress", str(error)) from error
        return _models_list_html(installed_only)

    @app.post(
        "/ui/partials/models/{model_id}/cancel",
        response_class=HTMLResponse,
        dependencies=[Depends(require_token)],
    )
    async def ui_cancel_download(model_id: str, installed_only: bool = Form(False)) -> HTMLResponse:
        manager.cancel_download(model_id)
        return _models_list_html(installed_only)

    @app.delete(
        "/ui/partials/models/{model_id}",
        response_class=HTMLResponse,
        dependencies=[Depends(require_token)],
    )
    async def ui_delete_model(model_id: str, installed_only: bool = Form(False)) -> HTMLResponse:
        try:
            if engine_manager is not None:
                engine_manager.forget_if_active(model_id)
            manager.delete(model_id)
        except DownloadInProgressError as error:
            raise APIProblem(
                409, "download_in_progress", "Cancel the download before deleting."
            ) from error
        return _models_list_html(installed_only)

    @app.post(
        "/ui/partials/models/{model_id}/select",
        response_class=HTMLResponse,
        dependencies=[Depends(require_token)],
    )
    async def ui_select_model(
        model_id: str, installed_only: bool = Form(False)
    ) -> HTMLResponse:
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
        entries = _model_entries()
        if installed_only:
            entries = [entry for entry in entries if entry.state == "installed"]
        return _html(
            models_list_fragment(entries, installed_only)
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
        return _html(
            settings_fragment(
                config, paths, configured.bind_host, configured.port, _tokens_fragment_str()
            )
        )

    def _tokens_fragment_str(*, new_token: tuple[str, str] | None = None) -> str:
        return tokens_fragment(_token_entries(), new_token=new_token)

    @app.get(
        "/ui/partials/tokens",
        response_class=HTMLResponse,
        dependencies=[Depends(require_token)],
    )
    async def ui_tokens() -> HTMLResponse:
        return _html(_tokens_fragment_str())

    @app.post(
        "/ui/partials/tokens",
        response_class=HTMLResponse,
        dependencies=[Depends(require_token)],
    )
    async def ui_create_token(
        label: str = Form(..., min_length=1, max_length=100),
    ) -> HTMLResponse:
        record, plaintext = token_store.create(label)
        return _html(_tokens_fragment_str(new_token=(record.label, plaintext)))

    @app.delete(
        "/ui/partials/tokens/{token_id}",
        response_class=HTMLResponse,
        dependencies=[Depends(require_token)],
    )
    async def ui_revoke_token(token_id: str) -> HTMLResponse:
        if token_id == BOOTSTRAP_TOKEN_ID:
            raise APIProblem(
                409,
                "bootstrap_token_not_revocable",
                "Rotate LOCALFLOW_TOKEN or its token file instead of revoking it here.",
            )
        token_store.revoke(token_id)
        return _html(_tokens_fragment_str())

    @app.post(
        "/ui/partials/tokens/{token_id}/rotate",
        response_class=HTMLResponse,
        dependencies=[Depends(require_token)],
    )
    async def ui_rotate_token(token_id: str) -> HTMLResponse:
        if token_id == BOOTSTRAP_TOKEN_ID:
            raise APIProblem(
                409,
                "bootstrap_token_not_rotatable",
                "Rotate LOCALFLOW_TOKEN or its token file instead of rotating it here.",
            )
        rotated = token_store.rotate(token_id)
        if rotated is None:
            raise APIProblem(404, "token_not_found", "This device token no longer exists.")
        record, plaintext = rotated
        return _html(_tokens_fragment_str(new_token=(record.label, plaintext)))

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
        "vocamac",
        "handy",
        "whisper.cpp",
        "whisperkit",
        "faster-whisper",
        "moonshine",
    }:
        raise RuntimeError("LOCALFLOW_ENGINE is not a supported engine.")
    manager = ModelManager(settings.resolved_models_dir())
    if settings.engine == "auto":
        from app.models.vocamac import VocaMacEngine
        from app.models.whisper_cpp import WhisperCppEngine

        vocamac = VocaMacEngine(
            settings.whisperkit_binary,
            settings.vocamac_model,
            app_path=settings.vocamac_app,
        )
        if vocamac.is_available():
            return vocamac
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
