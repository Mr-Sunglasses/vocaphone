from __future__ import annotations

import asyncio
import json
import sys
import urllib.request

import uvicorn

from app.audio import FFmpegNormalizer
from app.config import Settings
from app.main import create_app, select_engine
from app.service import TranscriptionService
from app.storage import SessionRepository


def serve() -> None:
    settings = Settings.from_env()
    uvicorn.run(
        create_app(settings),
        host=settings.bind_host,
        port=settings.port,
        access_log=False,
    )


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
        select_engine(settings),
        FFmpegNormalizer(),
    )
    print(f"removed {service.cleanup_expired()} expired session(s)")


if __name__ == "__main__":
    asyncio.run(asyncio.sleep(0))
