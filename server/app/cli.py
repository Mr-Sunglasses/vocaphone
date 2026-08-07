from __future__ import annotations

import asyncio
import json
import sys
import urllib.request

import uvicorn

from app.audio import FFmpegNormalizer
from app.config import WILDCARD_BIND_HOSTS, Settings, format_host_port, local_webui_url
from app.engines import StaticEngineProvider
from app.main import create_app, select_engine
from app.service import TranscriptionService
from app.storage import SessionRepository


def serve() -> None:
    settings = Settings.from_env()
    host = settings.bind_host
    token_source = "(from VOCAPHONE_TOKEN)" if _token_from_env() else "~/.config/vocaphone/token"
    print(f"vocaphone gateway listening on {format_host_port(host, settings.port)}")
    print(f"WebUI (this host): {local_webui_url(host, settings.port)}")
    if host in WILDCARD_BIND_HOSTS:
        print("Network access: use this host's LAN or Tailscale IP with the same port")
    print(f"Token: {token_source}")
    if not _token_from_env():
        print("  (cat ~/.config/vocaphone/token — enter that value in the phone app)")
    uvicorn.run(
        create_app(settings),
        host=host,
        port=settings.port,
        access_log=False,
    )


def _token_from_env() -> bool:
    import os

    return bool(os.environ.get("VOCAPHONE_TOKEN"))


def status() -> None:
    settings = Settings.from_env()
    try:
        health_url = f"{local_webui_url(settings.bind_host, settings.port)}health"
        with urllib.request.urlopen(health_url, timeout=2) as response:
            data = json.load(response)
    except Exception as error:
        print(f"gateway unreachable: {error}", file=sys.stderr)
        raise SystemExit(1) from error
    print(json.dumps(data, indent=2))


def diagnostics() -> None:
    settings = Settings.from_env()
    url = f"{local_webui_url(settings.bind_host, settings.port)}v1/admin/diagnostics"
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {settings.token}"})
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            data = json.load(response)
    except Exception as error:
        print(f"gateway unreachable or unauthorized: {error}", file=sys.stderr)
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
