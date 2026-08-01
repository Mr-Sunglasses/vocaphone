from __future__ import annotations

import asyncio
import json
import sys
import urllib.request

import uvicorn

from app.audio import FFmpegNormalizer
from app.config import Settings
from app.engines import StaticEngineProvider
from app.main import create_app, select_engine
from app.service import TranscriptionService
from app.storage import SessionRepository


def serve() -> None:
    settings = Settings.from_env()
    host = settings.bind_host
    display_host = "127.0.0.1" if host in {"0.0.0.0", "::"} else host
    token_source = "(from LOCALFLOW_TOKEN)" if _token_from_env() else "~/.config/localflow/token"
    print(f"Local Flow gateway listening on http://{display_host}:{settings.port}")
    print(f"WebUI:  http://{display_host}:{settings.port}/")
    print(f"Token:  {token_source}")
    uvicorn.run(
        create_app(settings),
        host=host,
        port=settings.port,
        access_log=False,
    )


def _token_from_env() -> bool:
    import os

    return bool(os.environ.get("LOCALFLOW_TOKEN"))


def status() -> None:
    settings = Settings.from_env()
    try:
        with urllib.request.urlopen(
            f"http://127.0.0.1:{settings.port}/health", timeout=2
        ) as response:
            data = json.load(response)
    except Exception as error:
        print(f"gateway unreachable: {error}", file=sys.stderr)
        raise SystemExit(1) from error
    print(json.dumps(data, indent=2))


def cleanup() -> None:
    settings = Settings.from_env()
    repository = SessionRepository(settings.data_dir / "sessions.sqlite3")
    repository.initialize()
    service = TranscriptionService(
        settings,
        repository,
        StaticEngineProvider(select_engine(settings)),
        FFmpegNormalizer(),
    )
    print(f"removed {service.cleanup_expired()} expired session(s)")


if __name__ == "__main__":
    asyncio.run(asyncio.sleep(0))
