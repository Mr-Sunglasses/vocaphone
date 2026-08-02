from __future__ import annotations

import json
from pathlib import Path

from app.runtime_config import RuntimeConfig


def test_legacy_moonshine_language_migrates_to_model_id(tmp_path: Path) -> None:
    path = tmp_path / "config.json"
    path.write_text(json.dumps({"engine": "moonshine", "moonshine_language": "es"}))

    config = RuntimeConfig.load(path)

    assert config.moonshine_language == "es"
    assert config.moonshine_model == "moonshine:es"


def test_moonshine_variant_round_trips_independently_of_language(tmp_path: Path) -> None:
    path = tmp_path / "config.json"
    original = RuntimeConfig(
        engine="moonshine",
        moonshine_model="moonshine:en-tiny-streaming",
        moonshine_language="en",
    )

    original.save(path)

    assert RuntimeConfig.load(path) == original


def test_new_model_selections_round_trip(tmp_path: Path) -> None:
    path = tmp_path / "config.json"
    original = RuntimeConfig(
        engine="sherpa-onnx",
        sherpa_model="sherpa-onnx:sensevoice-small-int8",
        mlx_audio_model="mlx-audio:whisper-large-v3-turbo-4bit",
    )

    original.save(path)

    assert RuntimeConfig.load(path) == original
