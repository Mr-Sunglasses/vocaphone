from __future__ import annotations

import os
import secrets
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path

DEFAULT_HANDY_FALLBACK_MODEL = "handy-computer/whisper-base-gguf/whisper-base-Q8_0.gguf"
WILDCARD_BIND_HOSTS = frozenset({"0.0.0.0", "::"})
MIGRATION_DOCS = (
    "https://github.com/VocaHQ/vocaphone/blob/main/docs/deployment.md"
    "#migrating-from-the-local-flow-working-name-v030"
)


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


def _xdg_config_home() -> Path:
    return Path(os.environ.get("XDG_CONFIG_HOME", "~/.config")).expanduser()


def _xdg_data_home() -> Path:
    return Path(os.environ.get("XDG_DATA_HOME", "~/.local/share")).expanduser()


def _env_path(name: str, default: Path) -> Path:
    """Resolve a path env var, treating missing/blank values as the default."""
    value = os.environ.get(name, "").strip()
    if not value:
        return default
    return Path(value).expanduser()


def _default_token_file() -> Path:
    return _xdg_config_home() / "vocaphone" / "token"


def _default_config_file() -> Path:
    return _xdg_config_home() / "vocaphone" / "config.json"


def _legacy_token_file() -> Path:
    return _xdg_config_home() / "localflow" / "token"


def _legacy_config_file() -> Path:
    return _xdg_config_home() / "localflow" / "config.json"


def _legacy_data_dir() -> Path:
    return _xdg_data_home() / "localflow"


def _display_path(path: Path | str) -> str:
    """Render paths with `~` instead of an absolute home prefix for operators."""
    text = str(path)
    home = str(Path.home())
    if home and (text == home or text.startswith(home + os.sep)):
        return "~" + text[len(home) :]
    return text


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
    token_file: Path = Path("~/.config/vocaphone/token")
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

    @property
    def token_file_display(self) -> str:
        return _display_path(self.token_file)

    @classmethod
    def from_env(cls) -> Settings:
        _warn_ignored_legacy_env()
        token_file = _env_path("VOCAPHONE_TOKEN_FILE", _default_token_file())
        token = os.environ.get("VOCAPHONE_TOKEN", "").strip()
        if not token and token_file.is_file():
            token = token_file.read_text(encoding="utf-8").strip()
        if not token:
            token = _resolve_or_migrate_token(token_file)
        if len(token) < 32:
            raise RuntimeError(
                "Set VOCAPHONE_TOKEN to at least 32 characters or create "
                f"{_display_path(token_file)} with mode 600."
            )
        data_dir = _env_path("VOCAPHONE_DATA_DIR", _xdg_data_home() / "vocaphone")
        if (
            "VOCAPHONE_DATA_DIR" not in os.environ
            or not os.environ.get("VOCAPHONE_DATA_DIR", "").strip()
        ):
            _warn_unmigrated_legacy_data(data_dir)
        config_path = _env_path("VOCAPHONE_CONFIG_FILE", _default_config_file())
        if (
            "VOCAPHONE_CONFIG_FILE" not in os.environ
            or not os.environ.get("VOCAPHONE_CONFIG_FILE", "").strip()
        ):
            _migrate_legacy_config_file(config_path)
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
            config_path=config_path,
            token_file=token_file,
            bind_host=os.environ.get("VOCAPHONE_BIND_HOST", "0.0.0.0"),
            port=int(os.environ.get("VOCAPHONE_PORT", "8765")),
            retention_hours=int(os.environ.get("VOCAPHONE_RETENTION_HOURS", "24")),
            delete_successful_audio=os.environ.get(
                "VOCAPHONE_DELETE_SUCCESSFUL_AUDIO", "true"
            ).lower()
            in {"1", "true", "yes"},
            debug=os.environ.get("VOCAPHONE_DEBUG", "false").lower() in {"1", "true", "yes"},
        )


def _legacy_env_names() -> list[str]:
    return sorted(name for name in os.environ if name.startswith("LOCALFLOW_"))


def _warn_ignored_legacy_env() -> None:
    leftover = _legacy_env_names()
    if not leftover:
        return
    print(
        "vocaphone: LOCALFLOW_* environment variables are obsolete "
        f"({', '.join(leftover)}). Rename them to VOCAPHONE_*. "
        "LOCALFLOW_TOKEN / LOCALFLOW_TOKEN_FILE are read only for a "
        f"one-time bootstrap migration. See {MIGRATION_DOCS}",
        file=sys.stderr,
    )


def _legacy_token_candidates() -> list[tuple[str, str]]:
    """Return (source label, token) pairs from the pre-rename Local Flow layout."""
    candidates: list[tuple[str, str]] = []
    env_token = os.environ.get("LOCALFLOW_TOKEN", "").strip()
    if env_token:
        candidates.append(("LOCALFLOW_TOKEN", env_token))
    legacy_file = _env_path("LOCALFLOW_TOKEN_FILE", _legacy_token_file())
    if legacy_file.is_file():
        file_token = legacy_file.read_text(encoding="utf-8").strip()
        if file_token:
            candidates.append((_display_path(legacy_file), file_token))
    return candidates


def _write_token_file(token_file: Path, token: str) -> None:
    token_file.parent.mkdir(parents=True, exist_ok=True)
    token_file.parent.chmod(0o700)
    descriptor = os.open(token_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.write(token + "\n")


def _token_conflict_error(token_file: Path, source: str) -> RuntimeError:
    return RuntimeError(
        f"{_display_path(token_file)} already contains a different bootstrap token "
        f"than the Local Flow source ({source}). Remove the conflicting file or unset "
        f"LOCALFLOW_TOKEN / remove {_display_path(_legacy_token_file())}, then retry so "
        f"paired phones keep the secret they already hold. See {MIGRATION_DOCS}"
    )


def _persist_migrated_token(token_file: Path, token: str, source: str) -> None:
    """Write a migrated token, replacing an empty destination if needed."""
    token_file.parent.mkdir(parents=True, exist_ok=True)
    token_file.parent.chmod(0o700)
    if token_file.is_file():
        existing = token_file.read_text(encoding="utf-8").strip()
        if existing == token:
            return
        if existing:
            raise _token_conflict_error(token_file, source)
        token_file.write_text(token + "\n", encoding="utf-8")
        token_file.chmod(0o600)
        return
    try:
        _write_token_file(token_file, token)
    except FileExistsError:
        # Another process created the destination between our checks.
        existing = token_file.read_text(encoding="utf-8").strip()
        if existing == token:
            return
        if not existing:
            token_file.write_text(token + "\n", encoding="utf-8")
            token_file.chmod(0o600)
            return
        raise _token_conflict_error(token_file, source) from None


def _resolve_or_migrate_token(token_file: Path) -> str:
    """Prefer a one-time Local Flow token migration over minting a new secret."""
    legacy = _legacy_token_candidates()
    if legacy:
        source, token = legacy[0]
        try:
            _persist_migrated_token(token_file, token, source)
        except OSError as exc:
            raise RuntimeError(
                "Found a Local Flow bootstrap token at "
                f"{source} but could not write {_display_path(token_file)}: {exc}. "
                f"Copy it manually, then restart. See {MIGRATION_DOCS}"
            ) from exc
        print(
            "vocaphone: migrated Local Flow bootstrap token from "
            f"{source} to {_display_path(token_file)}. Paired phones keep working. "
            f"See {MIGRATION_DOCS}",
            file=sys.stderr,
        )
        return token

    legacy_data = _legacy_data_dir()
    if legacy_data.is_dir() and any(legacy_data.iterdir()):
        raise RuntimeError(
            "Found Local Flow data at "
            f"{_display_path(legacy_data)} but no vocaphone bootstrap token. "
            f"Copy {_display_path(_legacy_token_file())} to {_display_path(token_file)} "
            f"(or set VOCAPHONE_TOKEN) before starting the gateway so paired "
            f"phones are not locked out. See {MIGRATION_DOCS}"
        )
    return _generate_token(token_file)


def _migrate_legacy_config_file(config_path: Path) -> None:
    if config_path.is_file() and config_path.read_text(encoding="utf-8").strip():
        return
    legacy = _legacy_config_file()
    if not legacy.is_file() or not legacy.read_text(encoding="utf-8").strip():
        return
    try:
        config_path.parent.mkdir(parents=True, exist_ok=True)
        config_path.parent.chmod(0o700)
        shutil.copy2(legacy, config_path)
        config_path.chmod(0o600)
    except OSError as exc:
        print(
            "vocaphone: could not migrate "
            f"{_display_path(legacy)} to {_display_path(config_path)}: {exc}. "
            f"Copy it manually if you need the previous WebUI settings. "
            f"See {MIGRATION_DOCS}",
            file=sys.stderr,
        )
        return
    print(
        "vocaphone: migrated Local Flow config from "
        f"{_display_path(legacy)} to {_display_path(config_path)}. "
        f"See {MIGRATION_DOCS}",
        file=sys.stderr,
    )


def _warn_unmigrated_legacy_data(data_dir: Path) -> None:
    if data_dir.exists():
        return
    legacy = _legacy_data_dir()
    if not legacy.is_dir() or not any(legacy.iterdir()):
        return
    print(
        "vocaphone: Local Flow data still exists at "
        f"{_display_path(legacy)}. "
        f"Move or copy it to {_display_path(data_dir)} (and rename any "
        ".localflow-model.json markers to .vocaphone-model.json) to keep "
        f"downloaded models and session history. See {MIGRATION_DOCS}",
        file=sys.stderr,
    )


def _generate_token(token_file: Path) -> str:
    """First-run friendly default: create a private token automatically."""
    token = secrets.token_urlsafe(48)
    try:
        _write_token_file(token_file, token)
    except OSError:
        return token
    return token
