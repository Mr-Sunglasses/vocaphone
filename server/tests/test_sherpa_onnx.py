from __future__ import annotations

import importlib.machinery
import sys
import types
import wave
from array import array
from pathlib import Path

import pytest

from app.catalog import CatalogModel
from app.errors import TranscriptionProcessError
from app.models.base import EngineTranscription, TranscriptionOptions
from app.models.sherpa_onnx import SherpaOnnxEngine


def _catalog(model_type: str = "sense_voice") -> CatalogModel:
    files = (
        ("model.int8.onnx", "tokens.txt")
        if model_type == "sense_voice"
        else ("encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt")
    )
    return CatalogModel(
        id=f"sherpa-onnx:{model_type}",
        engine="sherpa-onnx",
        key=model_type,
        label="Test",
        size_bytes=1,
        languages="English only",
        quality="Fast",
        minimum_ram_gb=1,
        marker_file=".localflow-model.json",
        required_files=files,
        model_type=model_type,
        language_codes=("en",),
    )


def _model_root(tmp_path: Path, model: CatalogModel) -> Path:
    root = tmp_path / model.key
    root.mkdir()
    (root / ".localflow-model.json").write_text("{}")
    for filename in model.required_files:
        (root / filename).write_bytes(b"model")
    return root


def _wave(path: Path) -> None:
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(16_000)
        output.writeframes(array("h", [0, 100, -100]).tobytes())


async def test_sherpa_keeps_one_recognizer_loaded(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    catalog_model = _catalog()
    root = _model_root(tmp_path, catalog_model)
    audio = tmp_path / "audio.wav"
    _wave(audio)
    constructions: list[dict[str, object]] = []

    class Result:
        text = " persistent sherpa result "

    class Stream:
        result = Result()

        def accept_waveform(self, sample_rate: int, samples: list[float]) -> None:
            assert sample_rate == 16_000
            assert len(samples) == 3

    class Recognizer:
        @classmethod
        def from_sense_voice(cls, **kwargs: object) -> Recognizer:
            constructions.append(kwargs)
            return cls()

        def create_stream(self) -> Stream:
            return Stream()

        def decode_stream(self, stream: Stream) -> None:
            assert isinstance(stream, Stream)

    module = types.ModuleType("sherpa_onnx")
    module.OfflineRecognizer = Recognizer  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "sherpa_onnx", module)
    monkeypatch.setattr(
        "app.models.sherpa_onnx.importlib.util.find_spec",
        lambda _: importlib.machinery.ModuleSpec("sherpa_onnx", loader=None),
    )

    engine = SherpaOnnxEngine(root, catalog_model, cpu_threads=2)
    first = await engine.transcribe(audio, TranscriptionOptions("en-US", "raw"))
    second = await engine.transcribe(audio, TranscriptionOptions("auto", "raw"))

    assert isinstance(first, EngineTranscription)
    assert first.text == "persistent sherpa result"
    assert second.model_load_ms == 0
    assert len(constructions) == 1
    assert constructions[0]["num_threads"] == 2
    assert constructions[0]["use_itn"] is True


async def test_sherpa_rejects_unsupported_language(tmp_path: Path) -> None:
    catalog_model = _catalog()
    engine = SherpaOnnxEngine(_model_root(tmp_path, catalog_model), catalog_model)

    with pytest.raises(TranscriptionProcessError, match="does not support es"):
        await engine.transcribe(
            tmp_path / "unused.wav",
            TranscriptionOptions("es", "casual"),
        )
