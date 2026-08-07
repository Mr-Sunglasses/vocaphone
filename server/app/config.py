from __future__ import annotations

import os
import secrets
from dataclasses import dataclass
from pathlib import Path

DEFAULT_HANDY_FALLBACK_MODEL = "handy-computer/whisper-base-gguf/whisper-base-Q8_0.gguf"
WILDCARD_BIND_HOSTS = frozenset({"0.0.0.0", "::"})


def format_host_port(host: str, port: int) -> str:
    """Format a listener address without pretending it is a browsable URL."""
    display_host = f"[{host}]" if ":" in host else host
    return f"{display_host}:{port}"


def local_webui_url(host: str, port: int) -> str:
    """Return the loopback URL that opens a listener from the same host."""
    if host == "0.0.0.0":
        host = "127.0.0.1"
    elif host == "::":
        host = "::1"
    return f"http://{format_host_port(host, port)}/"


@dataclass(frozen=True, slots=True)
class Settings:
    token: str
    data_dir: Path
    whisper_binary: Path
    whisper_model: Path
    engine: str = "auto"
    handy_binary: Path = Path("/Applications/Handy.app/Contents/MacOS/handy")
    handy_model: str | None = None
    handy_fallback_model: str | None = DEFAULT_HANDY_FALLBACK_MODEL
    vocamac_app: Path = Path("/Applications/VocaMac.app")
    vocamac_model: str | None = None
    whisperkit_binary: str = "whisperkit-cli"
    models_dir: Path | None = None
    config_path: Path = Path("~/.config/vocaphone/config.json")
    bind_host: str = "0.0.0.0"
    port: int = 8765
    maximum_upload_bytes: int = 25 * 1024 * 1024
    maximum_duration_seconds: int = 120
    retention_hours: int = 24
    delete_successful_audio: bool = True
    maximum_concurrent_transcriptions: int = 1
    debug: bool = False

    def resolved_models_dir(self) -> Path:
        return self.models_dir if self.models_dir is not None else self.data_dir / "models"

    @classmethod
    def from_env(cls) -> Settings:
        token_file = Path(
            os.environ.get(
                "VOCAPHONE_TOKEN_FILE",
                "~/.config/vocaphone/token",
            )
        ).expanduser()
        token = os.environ.get("VOCAPHONE_TOKEN", "")
        if not token and token_file.is_file():
            token = token_file.read_text(encoding="utf-8").strip()
        if not token:
            token = _generate_token(token_file)
        if len(token) < 32:
            raise RuntimeError(
                "Set VOCAPHONE_TOKEN to at least 32 characters or create "
                "~/.config/vocaphone/token with mode 600."
            )
        data_dir = Path(
            os.environ.get("VOCAPHONE_DATA_DIR", "~/.local/share/vocaphone")
        ).expanduser()
        return cls(
            token=token,
            data_dir=data_dir,
            whisper_binary=Path(
                os.environ.get("VOCAPHONE_WHISPER_BINARY", "/opt/homebrew/bin/whisper-cli")
            ).expanduser(),
            whisper_model=Path(
                os.environ.get(
                    "VOCAPHONE_WHISPER_MODEL",
                    "~/.local/share/whisper.cpp/models/ggml-base.en.bin",
                )
            ).expanduser(),
            engine=os.environ.get("VOCAPHONE_ENGINE", "auto").lower(),
            handy_binary=Path(
                os.environ.get(
                    "VOCAPHONE_HANDY_BINARY",
                    "/Applications/Handy.app/Contents/MacOS/handy",
                )
            ).expanduser(),
            handy_model=os.environ.get("VOCAPHONE_HANDY_MODEL") or None,
            handy_fallback_model=os.environ.get(
                "VOCAPHONE_HANDY_FALLBACK_MODEL",
                DEFAULT_HANDY_FALLBACK_MODEL,
            )
            or None,
            vocamac_app=Path(
                os.environ.get("VOCAPHONE_VOCAMAC_APP", "/Applications/VocaMac.app")
            ).expanduser(),
            vocamac_model=os.environ.get("VOCAPHONE_VOCAMAC_MODEL") or None,
            whisperkit_binary=os.environ.get("VOCAPHONE_WHISPERKIT_BINARY", "whisperkit-cli"),
            models_dir=Path(
                os.environ.get("VOCAPHONE_MODELS_DIR", str(data_dir / "models"))
            ).expanduser(),
            config_path=Path(
                os.environ.get(
                    "VOCAPHONE_CONFIG_FILE",
                    "~/.config/vocaphone/config.json",
                )
            ).expanduser(),
            bind_host=os.environ.get("VOCAPHONE_BIND_HOST", "0.0.0.0"),
            port=int(os.environ.get("VOCAPHONE_PORT", "8765")),
            retention_hours=int(os.environ.get("VOCAPHONE_RETENTION_HOURS", "24")),
            delete_successful_audio=os.environ.get(
                "VOCAPHONE_DELETE_SUCCESSFUL_AUDIO", "true"
            ).lower()
            in {"1", "true", "yes"},
            debug=os.environ.get("VOCAPHONE_DEBUG", "false").lower() in {"1", "true", "yes"},
        )


def _generate_token(token_file: Path) -> str:
    """First-run friendly default: create a private token automatically."""
    token = secrets.token_urlsafe(48)
    try:
        token_file.parent.mkdir(parents=True, exist_ok=True)
        token_file.parent.chmod(0o700)
        descriptor = os.open(token_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(token + "\n")
    except OSError:
        return token
    return token
