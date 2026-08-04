from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path

from app.schemas import AdminStatusResponse, ConfigResponse, DiagnosticsBundle, PathStatus

NEVER_INCLUDED: tuple[str, ...] = (
    "the bearer token",
    "recording audio",
    "transcript text",
    "session identifiers",
    "the local username in filesystem paths",
)


def redact_home_path(value: str) -> str:
    """Replace an absolute home-directory prefix with `~` for safer sharing."""
    home = str(Path.home())
    if home and (value == home or value.startswith(home + "/")):
        return "~" + value[len(home) :]
    return value


def _redact_optional_path(value: str | None) -> str | None:
    return redact_home_path(value) if value is not None else None


def build_diagnostics_bundle(
    status: AdminStatusResponse, config: ConfigResponse
) -> DiagnosticsBundle:
    # whisper_model/whisperkit_model/faster_whisper_model hold absolute
    # filesystem paths (set from `str(path)` in EngineManager.select_model),
    # unlike moonshine_model/sherpa_model/mlx_audio_model, which are opaque
    # catalog ids — redact only the fields that can actually contain one.
    redacted_config = config.model_copy(
        update={
            "whisper_model": _redact_optional_path(config.whisper_model),
            "whisperkit_model": _redact_optional_path(config.whisperkit_model),
            "faster_whisper_model": _redact_optional_path(config.faster_whisper_model),
        }
    )
    return DiagnosticsBundle(
        generated_at=datetime.now(UTC),
        version=status.version,
        engine=status.engine,
        system=status.system,
        dependencies=status.dependencies,
        paths=PathStatus(
            data_dir=redact_home_path(status.paths.data_dir),
            models_dir=redact_home_path(status.paths.models_dir),
            config_file=redact_home_path(status.paths.config_file),
            token_file=status.paths.token_file,
        ),
        bind_host=status.bind_host,
        port=status.port,
        setup=status.setup,
        metrics=status.metrics,
        readiness=status.readiness,
        config=redacted_config,
        never_included=list(NEVER_INCLUDED),
    )
