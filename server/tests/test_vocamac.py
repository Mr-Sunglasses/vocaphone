from __future__ import annotations

import plistlib
from pathlib import Path

from app.models.base import EngineTranscription, TranscriptionOptions
from app.models.vocamac import REQUIRED_COMPONENTS, VocaMacEngine

# Records the arguments of the last call so the one-shot CLI path stays inspectable.
FAKE_CLI = """#!/bin/sh
printf '%s\\n' "$@" > "$0.args"
case "$1" in
  serve) exit 1 ;;
esac
printf '%s\\n' 'private local result'
"""


def _write_model(models_dir: Path, variant: str, *, weight_bytes: int = 16) -> Path:
    """Create a complete VocaMac Core ML model folder."""
    directory = models_dir / variant
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "config.json").write_text("{}", encoding="utf-8")
    for component in REQUIRED_COMPONENTS:
        weights = directory / component / "weights"
        weights.mkdir(parents=True)
        (weights / "weight.bin").write_bytes(b"w" * weight_bytes)
        (directory / component / "metadata.json").write_text("[]", encoding="utf-8")
        (directory / component / "coremldata.bin").write_bytes(b"model")
    return directory


def _write_partial_model(models_dir: Path, variant: str) -> Path:
    """Create the folder an interrupted VocaMac download leaves behind."""
    directory = models_dir / variant
    for component in REQUIRED_COMPONENTS:
        (directory / component / "weights").mkdir(parents=True)
    return directory


def _write_preferences(tmp_path: Path, selected: str) -> None:
    with (tmp_path / "com.vocamac.app.plist").open("wb") as handle:
        plistlib.dump({"vocamac.selectedModelSize": selected}, handle)


def _build_engine(tmp_path: Path, *, model: str | None = None) -> tuple[VocaMacEngine, Path]:
    app_path = tmp_path / "VocaMac.app"
    app_path.mkdir(exist_ok=True)
    binary = tmp_path / "whisperkit-cli"
    binary.write_text(FAKE_CLI, encoding="utf-8")
    binary.chmod(0o700)
    models_dir = tmp_path / "support" / "models" / "models" / "argmaxinc" / "whisperkit-coreml"
    models_dir.mkdir(parents=True, exist_ok=True)
    engine = VocaMacEngine(
        str(binary),
        model,
        app_path=app_path,
        support_dir=tmp_path / "support",
        preferences_file=tmp_path / "com.vocamac.app.plist",
    )
    return engine, models_dir


async def test_vocamac_runs_the_model_selected_in_the_app(tmp_path: Path) -> None:
    engine, models_dir = _build_engine(tmp_path)
    _write_model(models_dir, "openai_whisper-tiny", weight_bytes=512)
    selected = _write_model(models_dir, "openai_whisper-small")
    _write_preferences(tmp_path, "small")
    audio = tmp_path / "audio.wav"
    audio.write_bytes(b"audio")

    health = await engine.health()
    transcript = await engine.transcribe(audio, TranscriptionOptions("auto", "raw"))
    arguments = (tmp_path / "whisperkit-cli.args").read_text(encoding="utf-8").splitlines()

    assert health.ready is True
    assert health.name == "vocamac:openai_whisper-small"
    assert isinstance(transcript, EngineTranscription)
    assert transcript.text == "private local result"
    assert arguments[arguments.index("--model-path") + 1] == str(selected)
    # VocaMac already downloaded the matching tokenizer, so reuse it.
    assert arguments[arguments.index("--download-tokenizer-path") + 1] == str(
        tmp_path / "support" / "models"
    )


async def test_vocamac_skips_an_interrupted_download(tmp_path: Path) -> None:
    engine, models_dir = _build_engine(tmp_path)
    _write_partial_model(models_dir, "openai_whisper-tiny")
    _write_model(models_dir, "openai_whisper-small")
    _write_preferences(tmp_path, "tiny")

    health = await engine.health()

    assert health.ready is True
    assert health.name == "vocamac:openai_whisper-small"


async def test_vocamac_prefers_the_largest_model_without_a_selection(tmp_path: Path) -> None:
    engine, models_dir = _build_engine(tmp_path)
    _write_model(models_dir, "openai_whisper-tiny", weight_bytes=16)
    largest = _write_model(models_dir, "openai_whisper-small", weight_bytes=512)

    assert (await engine.health()).name == f"vocamac:{largest.name}"


async def test_vocamac_honours_an_explicit_model_override(tmp_path: Path) -> None:
    engine, models_dir = _build_engine(tmp_path, model="tiny")
    pinned = _write_model(models_dir, "openai_whisper-tiny")
    _write_model(models_dir, "openai_whisper-small", weight_bytes=512)
    _write_preferences(tmp_path, "small")

    assert (await engine.health()).name == f"vocamac:{pinned.name}"


async def test_vocamac_never_substitutes_a_configured_model(tmp_path: Path) -> None:
    engine, models_dir = _build_engine(tmp_path, model="large-v3")
    _write_model(models_dir, "openai_whisper-small")

    health = await engine.health()

    assert engine.is_available() is False
    assert health.ready is False
    assert health.name == "vocamac:openai_whisper-large-v3"


async def test_vocamac_is_unavailable_without_the_app_or_a_model(tmp_path: Path) -> None:
    engine, models_dir = _build_engine(tmp_path)

    assert engine.is_available() is False
    assert (await engine.health()).name == "vocamac:no-model-selected"

    _write_model(models_dir, "openai_whisper-small")
    assert engine.is_available() is True

    engine.app_path.rmdir()
    assert engine.is_available() is False
    assert (await engine.health()).ready is False


async def test_vocamac_is_unavailable_without_whisperkit_cli(tmp_path: Path) -> None:
    engine, models_dir = _build_engine(tmp_path)
    _write_model(models_dir, "openai_whisper-small")
    Path(engine.whisperkit_binary).unlink()

    assert engine.is_available() is False
    assert (await engine.health()).ready is False
