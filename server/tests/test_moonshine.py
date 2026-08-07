from __future__ import annotations

import sys
from pathlib import Path
from types import ModuleType

import pytest

from app.errors import LanguageUnsupportedError
from app.models.base import TranscriptionOptions
from app.models.moonshine import MoonshineEngine


def model_root(tmp_path: Path, model_arch: int) -> Path:
    root = tmp_path / f"model-{model_arch}"
    root.mkdir()
    (root / ".vocaphone-model.json").write_text(
        '{"language":"zh","model_path":"weights","model_arch":' + str(model_arch) + "}",
        encoding="utf-8",
    )
    return root


def test_streaming_capability_comes_from_model_architecture(tmp_path: Path) -> None:
    assert MoonshineEngine(model_root(tmp_path, 5), "en").supports_streaming is True
    assert MoonshineEngine(model_root(tmp_path, 3), "en").supports_streaming is True
    assert MoonshineEngine(model_root(tmp_path, 1), "zh").supports_streaming is False


def test_non_latin_model_uses_expanded_decoder_budget(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    captured: dict[str, object] = {}
    module = ModuleType("moonshine_voice")

    class ModelArch:
        def __init__(self, value: int) -> None:
            self.value = value

    class Transcriber:
        def __init__(self, **kwargs: object) -> None:
            captured.update(kwargs)

    module.ModelArch = ModelArch  # type: ignore[attr-defined]
    module.Transcriber = Transcriber  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "moonshine_voice", module)

    MoonshineEngine(model_root(tmp_path, 1), "zh")._load_transcriber_sync()

    assert captured["options"] == {"max_tokens_per_second": "13.0"}


async def test_language_must_match_selected_moonshine_model(tmp_path: Path) -> None:
    engine = MoonshineEngine(model_root(tmp_path, 1), "zh")

    with pytest.raises(LanguageUnsupportedError, match="supports zh"):
        await engine.transcribe(
            tmp_path / "unused.wav",
            TranscriptionOptions(language="es", style="casual"),
        )
