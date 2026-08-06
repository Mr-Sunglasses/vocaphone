from __future__ import annotations

import importlib.machinery
import sys
import types
from pathlib import Path

import pytest

from app.catalog import CatalogModel
from app.errors import LanguageUnsupportedError
from app.models.base import EngineTranscription, TranscriptionOptions
from app.models.mlx_audio import MLXAudioEngine


async def test_mlx_audio_keeps_one_model_loaded(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    root = tmp_path / "mlx-model"
    root.mkdir()
    (root / "model.safetensors").write_bytes(b"model")
    audio = tmp_path / "audio.wav"
    audio.write_bytes(b"audio")
    constructions: list[Path] = []

    class Result:
        text = " persistent mlx result "

    class Model:
        def generate(self, audio_path: str, *, language: str = "en") -> Result:
            assert audio_path == str(audio)
            assert language == "en"
            return Result()

    def load(path: Path) -> Model:
        constructions.append(path)
        return Model()

    module = types.ModuleType("mlx_audio")
    stt_module = types.ModuleType("mlx_audio.stt")
    utils_module = types.ModuleType("mlx_audio.stt.utils")
    utils_module.load = load  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "mlx_audio", module)
    monkeypatch.setitem(sys.modules, "mlx_audio.stt", stt_module)
    monkeypatch.setitem(sys.modules, "mlx_audio.stt.utils", utils_module)
    monkeypatch.setattr(
        "app.models.mlx_audio.importlib.util.find_spec",
        lambda _: importlib.machinery.ModuleSpec("mlx_audio", loader=None),
    )
    monkeypatch.setattr("app.models.mlx_audio.platform.system", lambda: "Darwin")
    monkeypatch.setattr("app.models.mlx_audio.platform.machine", lambda: "arm64")
    catalog_model = CatalogModel(
        id="mlx-audio:test",
        engine="mlx-audio",
        key="test",
        label="Test",
        size_bytes=1,
        languages="Multilingual",
        quality="Fast",
        minimum_ram_gb=1,
    )

    engine = MLXAudioEngine(root, catalog_model)
    first = await engine.transcribe(audio, TranscriptionOptions("en-US", "raw"))
    second = await engine.transcribe(audio, TranscriptionOptions("en", "raw"))

    assert isinstance(first, EngineTranscription)
    assert first.text == "persistent mlx result"
    assert second.model_load_ms == 0
    assert constructions == [root]


async def test_mlx_rejects_a_language_the_model_cannot_serve(tmp_path: Path) -> None:
    """English-only MLX entries (Parakeet v2, Granite Speech) must refuse other
    languages with the specific error the API turns into `language_unsupported`."""
    root = tmp_path / "mlx-model"
    root.mkdir()
    (root / "model.safetensors").write_bytes(b"model")
    catalog_model = CatalogModel(
        id="mlx-audio:english-only",
        engine="mlx-audio",
        key="english-only",
        label="Test",
        size_bytes=1,
        languages="English only",
        quality="Fast",
        minimum_ram_gb=1,
        language_codes=("en",),
    )

    engine = MLXAudioEngine(root, catalog_model)

    with pytest.raises(LanguageUnsupportedError, match="does not support hi"):
        await engine.transcribe(
            tmp_path / "unused.wav",
            TranscriptionOptions(language="hi", style="raw"),
        )
