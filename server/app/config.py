from __future__ import annotations

import os
import secrets
from dataclasses import dataclass
from pathlib import Path

DEFAULT_HANDY_FALLBACK_MODEL = "handy-computer/whisper-base-gguf/whisper-base-Q8_0.gguf"


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
    whisperkit_binary: str = "whisperkit-cli"
    models_dir: Path | None = None
    config_path: Path = Path("~/.config/localflow/config.json")
    bind_host: str = "0.0.0.0"
    port: int = 8765
    maximum_upload_bytes: int = 25 * 1024 * 1024
    maximum_duration_seconds: int = 120
    retention_hours: int = 24
    delete_successful_audio: bool = True
    maximum_concurrent_transcriptions: int = 1

    def resolved_models_dir(self) -> Path:
        return self.models_dir if self.models_dir is not None else self.data_dir / "models"

    @classmethod
    def from_env(cls) -> Settings:
        token_file = Path(
            os.environ.get(
                "LOCALFLOW_TOKEN_FILE",
                "~/.config/localflow/token",
            )
        ).expanduser()
        token = os.environ.get("LOCALFLOW_TOKEN", "")
        if not token and token_file.is_file():
            token = token_file.read_text(encoding="utf-8").strip()
        if not token:
            token = _generate_token(token_file)
        if len(token) < 32:
            raise RuntimeError(
                "Set LOCALFLOW_TOKEN to at least 32 characters or create "
                "~/.config/localflow/token with mode 600."
            )
        data_dir = Path(
            os.environ.get("LOCALFLOW_DATA_DIR", "~/.local/share/localflow")
        ).expanduser()
        return cls(
            token=token,
            data_dir=data_dir,
            whisper_binary=Path(
                os.environ.get("LOCALFLOW_WHISPER_BINARY", "/opt/homebrew/bin/whisper-cli")
            ).expanduser(),
            whisper_model=Path(
                os.environ.get(
                    "LOCALFLOW_WHISPER_MODEL",
                    "~/.local/share/whisper.cpp/models/ggml-base.en.bin",
                )
            ).expanduser(),
            engine=os.environ.get("LOCALFLOW_ENGINE", "auto").lower(),
            handy_binary=Path(
                os.environ.get(
                    "LOCALFLOW_HANDY_BINARY",
                    "/Applications/Handy.app/Contents/MacOS/handy",
                )
            ).expanduser(),
            handy_model=os.environ.get("LOCALFLOW_HANDY_MODEL") or None,
            handy_fallback_model=os.environ.get(
                "LOCALFLOW_HANDY_FALLBACK_MODEL",
                DEFAULT_HANDY_FALLBACK_MODEL,
            )
            or None,
            whisperkit_binary=os.environ.get("LOCALFLOW_WHISPERKIT_BINARY", "whisperkit-cli"),
            models_dir=Path(
                os.environ.get("LOCALFLOW_MODELS_DIR", str(data_dir / "models"))
            ).expanduser(),
            config_path=Path(
                os.environ.get(
                    "LOCALFLOW_CONFIG_FILE",
                    "~/.config/localflow/config.json",
                )
            ).expanduser(),
            bind_host=os.environ.get("LOCALFLOW_BIND_HOST", "127.0.0.1"),
            port=int(os.environ.get("LOCALFLOW_PORT", "8765")),
            retention_hours=int(os.environ.get("LOCALFLOW_RETENTION_HOURS", "24")),
            delete_successful_audio=os.environ.get(
                "LOCALFLOW_DELETE_SUCCESSFUL_AUDIO", "true"
            ).lower()
            in {"1", "true", "yes"},
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
