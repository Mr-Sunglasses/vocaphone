from __future__ import annotations

from pathlib import Path

from app.diagnostics import NEVER_INCLUDED, build_diagnostics_bundle, redact_home_path
from app.schemas import (
    AdminStatusResponse,
    ConfigResponse,
    DependencyStatus,
    EngineStatus,
    OperationalMetricsStatus,
    PathStatus,
    ReadinessStatus,
    SetupChecklist,
    SystemStatus,
)


def _status(paths: PathStatus) -> AdminStatusResponse:
    return AdminStatusResponse(
        version="0.2.0",
        engine=EngineStatus(id="whisper.cpp", name="whisper.cpp:ggml-base.en.bin", ready=True),
        system=SystemStatus(
            os="Darwin",
            arch="arm64",
            chip="Apple M2",
            ram_gb=16.0,
            is_apple_silicon=True,
            logical_cpus=8,
            effective_cpus=8.0,
            containerized=False,
            accelerators=["CPU", "Metal/Core ML"],
            cpu_features=[],
        ),
        dependencies=[DependencyStatus(name="FFmpeg", available=True, path="/usr/bin/ffmpeg")],
        paths=paths,
        bind_host="0.0.0.0",
        port=8765,
        setup=SetupChecklist(
            token_configured=True,
            ffmpeg_available=True,
            engine_binary_available=True,
            model_installed=True,
            engine_ready=True,
        ),
        metrics=OperationalMetricsStatus(
            uptime_seconds=42,
            queue_depth=0,
            active_transcriptions=0,
            concurrency_limit=1,
            successful_transcriptions=3,
            failed_transcriptions=0,
            rejected_transcriptions=0,
            average_latency_ms=500,
            last_latency_ms=500,
        ),
        readiness=ReadinessStatus(probe_age_seconds=1.0, warmup_state="complete", warmed_bytes=0),
    )


def _config() -> ConfigResponse:
    return ConfigResponse(engine="auto", available_engines=["auto", "whisper.cpp"])


def test_redact_home_path_replaces_home_prefix() -> None:
    home = str(Path.home())
    assert redact_home_path(f"{home}/.local/share/localflow") == "~/.local/share/localflow"
    assert redact_home_path(home) == "~"


def test_redact_home_path_leaves_other_paths_untouched() -> None:
    assert redact_home_path("/data/models") == "/data/models"


def test_build_diagnostics_bundle_redacts_paths_and_lists_exclusions() -> None:
    home = str(Path.home())
    status = _status(
        PathStatus(
            data_dir=f"{home}/.local/share/localflow",
            models_dir=f"{home}/.local/share/localflow/models",
            config_file=f"{home}/.config/localflow/config.json",
            token_file="~/.config/localflow/token",
        )
    )
    bundle = build_diagnostics_bundle(status, _config())
    assert bundle.paths.data_dir == "~/.local/share/localflow"
    assert bundle.paths.models_dir == "~/.local/share/localflow/models"
    assert bundle.paths.config_file == "~/.config/localflow/config.json"
    assert bundle.never_included == list(NEVER_INCLUDED)
    dumped = bundle.model_dump_json()
    assert home not in dumped
    assert "Bearer" not in dumped


def test_build_diagnostics_bundle_redacts_config_model_paths() -> None:
    """whisper_model/whisperkit_model/faster_whisper_model are absolute paths
    (set via `str(path)` in EngineManager.select_model), unlike
    moonshine_model/sherpa_model/mlx_audio_model, which are opaque catalog
    ids — both must survive the bundle, but only the paths get redacted."""
    home = str(Path.home())
    status = _status(
        PathStatus(
            data_dir=f"{home}/.local/share/localflow",
            models_dir=f"{home}/.local/share/localflow/models",
            config_file=f"{home}/.config/localflow/config.json",
            token_file="~/.config/localflow/token",
        )
    )
    config = ConfigResponse(
        engine="whisper.cpp",
        available_engines=["auto", "whisper.cpp"],
        whisper_model=f"{home}/.local/share/localflow/models/whisper.cpp/ggml-base.en.bin",
        whisperkit_model=f"{home}/.local/share/localflow/models/whisperkit/openai_whisper-tiny",
        faster_whisper_model=f"{home}/.local/share/localflow/models/faster-whisper/tiny.en",
        sherpa_model="sherpa-onnx:sensevoice-small-int8",
    )

    bundle = build_diagnostics_bundle(status, config)

    assert (
        bundle.config.whisper_model
        == "~/.local/share/localflow/models/whisper.cpp/ggml-base.en.bin"
    )
    assert (
        bundle.config.whisperkit_model
        == "~/.local/share/localflow/models/whisperkit/openai_whisper-tiny"
    )
    assert (
        bundle.config.faster_whisper_model
        == "~/.local/share/localflow/models/faster-whisper/tiny.en"
    )
    assert bundle.config.sherpa_model == "sherpa-onnx:sensevoice-small-int8"
    assert home not in bundle.model_dump_json()
