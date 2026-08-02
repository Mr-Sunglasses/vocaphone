from __future__ import annotations

from pathlib import Path

import pytest

from app.catalog import CatalogModel
from app.config import Settings
from app.engines import EngineManager
from app.model_manager import ModelManager
from app.models.mlx_audio import MLXAudioEngine
from app.models.sherpa_onnx import SherpaOnnxEngine
from app.runtime_config import RuntimeConfig


@pytest.mark.parametrize(
    ("catalog_model", "expected_type", "config_field"),
    [
        (
            CatalogModel(
                id="sherpa-onnx:test",
                engine="sherpa-onnx",
                key="test",
                label="Sherpa test",
                size_bytes=1,
                languages="English only",
                quality="Fast",
                minimum_ram_gb=1,
                marker_file=".localflow-model.json",
                required_files=("model.int8.onnx", "tokens.txt"),
                model_type="sense_voice",
            ),
            SherpaOnnxEngine,
            "sherpa_model",
        ),
        (
            CatalogModel(
                id="mlx-audio:test",
                engine="mlx-audio",
                key="test",
                label="MLX test",
                size_bytes=1,
                languages="Multilingual",
                quality="Fast",
                minimum_ram_gb=1,
                marker_file="model.safetensors",
                apple_silicon_only=True,
            ),
            MLXAudioEngine,
            "mlx_audio_model",
        ),
    ],
)
def test_model_selection_builds_new_engine_and_persists_id(
    tmp_path: Path,
    catalog_model: CatalogModel,
    expected_type: type[SherpaOnnxEngine] | type[MLXAudioEngine],
    config_field: str,
) -> None:
    manager = ModelManager(tmp_path / "models", catalog=(catalog_model,))
    root = manager.model_path(catalog_model)
    root.mkdir(parents=True)
    if catalog_model.marker_file:
        (root / catalog_model.marker_file).write_bytes(b"model")
    runtime = RuntimeConfig()
    settings = Settings(
        token="test-token-with-at-least-thirty-two-characters",
        data_dir=tmp_path,
        whisper_binary=tmp_path / "whisper-cli",
        whisper_model=tmp_path / "whisper.bin",
    )
    config_path = tmp_path / "config.json"
    engines = EngineManager(settings, runtime, config_path, manager)

    engines.select_model(catalog_model.id)

    assert isinstance(engines.current(), expected_type)
    assert runtime.engine == catalog_model.engine
    assert getattr(runtime, config_field) == catalog_model.id
    assert getattr(RuntimeConfig.load(config_path), config_field) == catalog_model.id
