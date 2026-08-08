from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import urllib.request

import uvicorn

from app.audio import FFmpegNormalizer
from app.config import (
    WILDCARD_BIND_HOSTS,
    Settings,
    _default_config_file,
    _default_token_file,
    _env_path,
    format_host_port,
    local_webui_url,
)
from app.engines import StaticEngineProvider
from app.main import create_app, select_engine
from app.pairing import (
    default_pairing_url,
    encode_pairing_payload,
    qr_ascii_for_payload,
)
from app.runtime_config import RuntimeConfig
from app.service import TranscriptionService
from app.storage import SessionRepository


def serve() -> None:
    settings = Settings.from_env()
    host = settings.bind_host
    token_path = settings.token_file_display
    token_source = "(from VOCAPHONE_TOKEN)" if _token_from_env() else token_path
    print(f"vocaphone gateway listening on {format_host_port(host, settings.port)}")
    print(f"WebUI (this host): {local_webui_url(host, settings.port)}")
    if host in WILDCARD_BIND_HOSTS:
        print("Network access: use this host's LAN or Tailscale IP with the same port")
    print(f"Token: {token_source}")
    if not _token_from_env():
        print(f"  (cat {token_path} — enter that value in the phone app)")
        print("  or: just token  (prints a terminal QR for headless phone pairing)")
    uvicorn.run(
        create_app(settings),
        host=host,
        port=settings.port,
        access_log=False,
    )


def _token_from_env() -> bool:
    return bool(os.environ.get("VOCAPHONE_TOKEN", "").strip())


def _load_existing_bootstrap_token() -> str:
    """Return the bootstrap token without minting a new secret.

    Path resolution matches :meth:`Settings.from_env` (blank
    ``VOCAPHONE_TOKEN_FILE`` falls back to the default; ``~`` and
    ``XDG_CONFIG_HOME`` are expanded the same way).
    """
    token = os.environ.get("VOCAPHONE_TOKEN", "").strip()
    if token:
        return token
    token_file = _env_path("VOCAPHONE_TOKEN_FILE", _default_token_file())
    if not token_file.is_file():
        print(
            "No token yet — the gateway writes one on first start: just run",
            file=sys.stderr,
        )
        raise SystemExit(1)
    token = token_file.read_text(encoding="utf-8").strip()
    if not token:
        print(f"Token file is empty: {token_file}", file=sys.stderr)
        raise SystemExit(1)
    return token


def _saved_pairing_url() -> str | None:
    config_path = _env_path("VOCAPHONE_CONFIG_FILE", _default_config_file())
    return RuntimeConfig.load(config_path).pairing_url


def token() -> None:
    """Print the bootstrap token, and a terminal pairing QR when useful.

    Interactive terminals get the phone-scannable pairing QR (same JSON the
    WebUI encodes). Piped / ``--plain`` output stays a single line so scripts
    can still do ``TOKEN=$(just token --plain)``.
    """
    parser = argparse.ArgumentParser(
        prog="vocaphone-token",
        description="Show the bootstrap bearer token and an optional terminal pairing QR.",
    )
    parser.add_argument(
        "--plain",
        action="store_true",
        help="Print only the token (always used when stdout is not a TTY).",
    )
    args = parser.parse_args()
    secret = _load_existing_bootstrap_token()
    plain = args.plain or not sys.stdout.isatty()
    if plain:
        print(secret)
        return

    port = int(os.environ.get("VOCAPHONE_PORT", "8765"))
    gateway_url = default_pairing_url(port, saved_pairing_url=_saved_pairing_url())
    print(f"Token: {secret}")
    if gateway_url is None:
        print(
            "No phone-reachable gateway address found. Set VOCAPHONE_PUBLIC_URL "
            f"or VOCAPHONE_PAIRING_URL (for example http://192.168.1.20:{port}), "
            "or pick an address in the WebUI pairing card.",
            file=sys.stderr,
        )
        return

    payload = encode_pairing_payload(gateway_url, secret)
    print(f"Gateway: {gateway_url}")
    print("Scan with the phone app (Settings → Scan pairing QR / Gateway → Scan QR):")
    print()
    print(qr_ascii_for_payload(payload), end="")
    print()
    print(
        "Override the encoded address with VOCAPHONE_PUBLIC_URL, VOCAPHONE_PAIRING_URL, "
        "or the WebUI pairing card."
    )


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
