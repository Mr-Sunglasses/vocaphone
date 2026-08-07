from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import asynccontextmanager, suppress
from pathlib import Path

from fastapi import FastAPI, Request, Response
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from app.audio import FFmpegNormalizer
from app.config import Settings
from app.context import VERSION, GatewayContext
from app.engines import (
    EngineManager,
    EngineProvider,
    StaticEngineProvider,
    build_engine,
    close_engine,
)
from app.errors import APIProblem
from app.model_manager import ModelManager
from app.models.base import AudioNormalizer, TranscriptionEngine
from app.readiness import ReadinessMonitor
from app.routes import (
    admin_config,
    admin_models,
    admin_status,
    admin_tokens,
    health,
    pairing,
    sessions,
    streaming,
)
from app.runtime_config import RuntimeConfig
from app.schemas import ErrorDetail, ErrorEnvelope
from app.service import TranscriptionService
from app.storage import SessionRepository
from app.tokens import TokenStore

WEBUI_DIR = Path(__file__).parent / "webui"


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
    ctx = GatewayContext(
        settings=configured,
        repository=repository,
        manager=manager,
        token_store=token_store,
        engine_provider=engine_provider,
        engine_manager=engine_manager,
        service=service,
        readiness=readiness,
        pairing_config=pairing_config,
        config_path=config_path,
    )

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
        title="vocaphone gateway",
        version=VERSION,
        docs_url=None,
        redoc_url=None,
        openapi_url="/openapi.json" if configured.debug else None,
        lifespan=lifespan,
    )
    app.state.ctx = ctx

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

    app.include_router(health.router)
    app.include_router(sessions.router)
    app.include_router(streaming.router)
    app.include_router(admin_status.router)
    app.include_router(admin_tokens.router)
    app.include_router(admin_models.router)
    app.include_router(admin_config.router)
    app.include_router(pairing.router)

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
        raise RuntimeError("VOCAPHONE_ENGINE is not a supported engine.")
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
