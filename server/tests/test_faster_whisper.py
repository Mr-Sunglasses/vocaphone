from __future__ import annotations

import importlib.machinery
import sys
import types
from pathlib import Path

from pytest import MonkeyPatch

from app.models.base import EngineTranscription, TranscriptionOptions
from app.models.faster_whisper import FasterWhisperEngine


async def test_faster_whisper_keeps_one_model_loaded(
    tmp_path: Path, monkeypatch: MonkeyPatch
) -> None:
    model_path = tmp_path / "tiny.en"
    model_path.mkdir()
    (model_path / "model.bin").write_bytes(b"model")
    audio_path = tmp_path / "audio.wav"
    audio_path.write_bytes(b"audio")
    constructions: list[dict[str, object]] = []

    class Segment:
        text = " persistent result "

    class FakeWhisperModel:
        def __init__(self, _: str, **options: object) -> None:
            constructions.append(options)

        def transcribe(self, _: str, **options: object) -> tuple[list[Segment], object]:
            assert options["beam_size"] == 1
            return [Segment()], object()

    module = types.ModuleType("faster_whisper")
    module.WhisperModel = FakeWhisperModel  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "faster_whisper", module)
    monkeypatch.setattr(
        "app.models.faster_whisper.importlib.util.find_spec",
        lambda _: importlib.machinery.ModuleSpec("faster_whisper", loader=None),
    )

    engine = FasterWhisperEngine(model_path, device="cpu", compute_type="int8", cpu_threads=2)
    first = await engine.transcribe(audio_path, TranscriptionOptions("en", "raw"))
    second = await engine.transcribe(audio_path, TranscriptionOptions("en", "raw"))

    assert isinstance(first, EngineTranscription)
    assert first.text == "persistent result"
    assert second.model_load_ms == 0
    assert constructions == [
        {
            "device": "cpu",
            "compute_type": "int8",
            "cpu_threads": 2,
            "num_workers": 1,
            "local_files_only": True,
        }
    ]
