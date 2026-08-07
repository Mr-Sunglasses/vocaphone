from __future__ import annotations

import hmac
from dataclasses import dataclass
from pathlib import Path

from fastapi import Depends, Header, Request

from app.config import Settings
from app.engines import EngineManager, EngineProvider
from app.errors import APIProblem
from app.model_manager import ModelManager
from app.readiness import ReadinessMonitor
from app.runtime_config import RuntimeConfig
from app.service import TranscriptionService
from app.storage import SessionRepository
from app.tokens import TokenStore

VERSION = "0.2.0"
TOKEN_FILE_HINT = "~/.config/localflow/token"
BOOTSTRAP_TOKEN_ID = "bootstrap"


@dataclass
class GatewayContext:
    """The state every route needs, built once in `create_app()`.

    Stored on `app.state.ctx` and reached through the `get_context` dependency
    instead of route-module closures, so router modules can be plain,
    independently importable `APIRouter()` instances.
    """

    settings: Settings
    repository: SessionRepository
    manager: ModelManager
    token_store: TokenStore
    engine_provider: EngineProvider
    engine_manager: EngineManager | None
    service: TranscriptionService
    readiness: ReadinessMonitor
    pairing_config: RuntimeConfig
    config_path: Path

    def token_matches(self, supplied: str) -> bool:
        if hmac.compare_digest(supplied, self.settings.token):
            return True
        return self.token_store.matches(supplied)

    def token_is_valid(self, authorization: str | None) -> bool:
        prefix = "Bearer "
        supplied = (
            authorization[len(prefix) :]
            if authorization and authorization.startswith(prefix)
            else ""
        )
        return self.token_matches(supplied)


def get_context(request: Request) -> GatewayContext:
    ctx: GatewayContext = request.app.state.ctx
    return ctx


def require_token(
    ctx: GatewayContext = Depends(get_context),
    authorization: str | None = Header(default=None),
) -> None:
    if not ctx.token_is_valid(authorization):
        raise APIProblem(401, "unauthorized", "A valid bearer token is required.")
