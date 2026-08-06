from __future__ import annotations

import importlib.machinery
import sys
import types
import wave
from array import array
from pathlib import Path

import pytest

from app.catalog import CatalogModel
from app.errors import EngineUnavailableError, LanguageUnsupportedError
from app.models.base import EngineTranscription, TranscriptionOptions
from app.models.sherpa_onnx import SherpaOnnxEngine, _SherpaOnnxStreamAdapter


def _catalog(
    model_type: str = "sense_voice", required_files: tuple[str, ...] | None = None
) -> CatalogModel:
    if required_files is not None:
        files = required_files
    elif model_type in ("sense_voice", "nemo_ctc"):
        files = ("model.int8.onnx", "tokens.txt")
    elif model_type == "nemo_canary":
        files = ("encoder.int8.onnx", "decoder.int8.onnx", "tokens.txt")
    else:
        files = ("encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt")
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
        # Some families (Qwen3-ASR) list files inside a nested tokenizer directory.
        (root / filename).parent.mkdir(parents=True, exist_ok=True)
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


def _fake_recognizer_module(
    factory_name: str,
    constructions: list[dict[str, object]],
    monkeypatch: pytest.MonkeyPatch,
    *,
    attr_name: str = "OfflineRecognizer",
) -> None:
    class Recognizer:
        pass

    def factory(cls: type[Recognizer], **kwargs: object) -> Recognizer:
        constructions.append(kwargs)
        return cls()

    setattr(Recognizer, factory_name, classmethod(factory))
    module = types.ModuleType("sherpa_onnx")
    setattr(module, attr_name, Recognizer)
    monkeypatch.setitem(sys.modules, "sherpa_onnx", module)


def test_sherpa_nemo_ctc_loads_with_its_own_files(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    catalog_model = _catalog("nemo_ctc")
    root = _model_root(tmp_path, catalog_model)
    constructions: list[dict[str, object]] = []
    _fake_recognizer_module("from_nemo_ctc", constructions, monkeypatch)
    monkeypatch.setattr(
        "app.models.sherpa_onnx.importlib.util.find_spec",
        lambda _: importlib.machinery.ModuleSpec("sherpa_onnx", loader=None),
    )

    SherpaOnnxEngine(root, catalog_model)._load_recognizer_sync()

    assert len(constructions) == 1
    assert constructions[0]["model"] == str(root / "model.int8.onnx")
    assert constructions[0]["tokens"] == str(root / "tokens.txt")


def test_sherpa_nemo_canary_loads_english_only_by_default(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    catalog_model = _catalog("nemo_canary")
    root = _model_root(tmp_path, catalog_model)
    constructions: list[dict[str, object]] = []
    _fake_recognizer_module("from_nemo_canary", constructions, monkeypatch)
    monkeypatch.setattr(
        "app.models.sherpa_onnx.importlib.util.find_spec",
        lambda _: importlib.machinery.ModuleSpec("sherpa_onnx", loader=None),
    )

    SherpaOnnxEngine(root, catalog_model)._load_recognizer_sync()

    assert len(constructions) == 1
    assert constructions[0]["encoder"] == str(root / "encoder.int8.onnx")
    assert constructions[0]["decoder"] == str(root / "decoder.int8.onnx")
    assert constructions[0]["tokens"] == str(root / "tokens.txt")
    # No src_lang/tgt_lang override: sherpa-onnx defaults both to "en", matching the
    # English-only catalog entry this project currently ships for Canary.
    assert "src_lang" not in constructions[0]
    assert "tgt_lang" not in constructions[0]


def test_sherpa_nemo_transducer_uses_each_files_own_quantization(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """GigaAM's RNNT export ships an INT8 encoder but a non-quantized decoder/joiner."""
    catalog_model = _catalog(
        "nemo_transducer",
        required_files=("encoder.int8.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"),
    )
    root = _model_root(tmp_path, catalog_model)
    constructions: list[dict[str, object]] = []
    _fake_recognizer_module("from_transducer", constructions, monkeypatch)
    monkeypatch.setattr(
        "app.models.sherpa_onnx.importlib.util.find_spec",
        lambda _: importlib.machinery.ModuleSpec("sherpa_onnx", loader=None),
    )

    SherpaOnnxEngine(root, catalog_model)._load_recognizer_sync()

    assert constructions[0]["encoder"] == str(root / "encoder.int8.onnx")
    assert constructions[0]["decoder"] == str(root / "decoder.onnx")
    assert constructions[0]["joiner"] == str(root / "joiner.onnx")


def test_sherpa_dolphin_loads_a_single_file_ctc(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    for model_type, factory in (("dolphin_ctc", "from_dolphin_ctc"),):
        catalog_model = _catalog(model_type, required_files=("model.int8.onnx", "tokens.txt"))
        root = _model_root(tmp_path, catalog_model)
        constructions: list[dict[str, object]] = []
        _fake_recognizer_module(factory, constructions, monkeypatch)
        monkeypatch.setattr(
            "app.models.sherpa_onnx.importlib.util.find_spec",
            lambda _: importlib.machinery.ModuleSpec("sherpa_onnx", loader=None),
        )

        SherpaOnnxEngine(root, catalog_model)._load_recognizer_sync()

        assert constructions[0]["model"] == str(root / "model.int8.onnx")
        assert constructions[0]["tokens"] == str(root / "tokens.txt")


def test_sherpa_qwen3_asr_loads_a_tokenizer_directory(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """This family takes a Hugging Face tokenizer folder, not a `tokens.txt`."""
    catalog_model = _catalog(
        "qwen3_asr",
        required_files=(
            "conv_frontend.onnx",
            "encoder.int8.onnx",
            "decoder.int8.onnx",
            "tokenizer/vocab.json",
            "tokenizer/merges.txt",
            "tokenizer/tokenizer_config.json",
        ),
    )
    root = _model_root(tmp_path, catalog_model)
    constructions: list[dict[str, object]] = []
    _fake_recognizer_module("from_qwen3_asr", constructions, monkeypatch)
    monkeypatch.setattr(
        "app.models.sherpa_onnx.importlib.util.find_spec",
        lambda _: importlib.machinery.ModuleSpec("sherpa_onnx", loader=None),
    )

    SherpaOnnxEngine(root, catalog_model)._load_recognizer_sync()

    assert constructions[0]["conv_frontend"] == str(root / "conv_frontend.onnx")
    assert constructions[0]["encoder"] == str(root / "encoder.int8.onnx")
    assert constructions[0]["decoder"] == str(root / "decoder.int8.onnx")
    assert constructions[0]["tokenizer"] == str(root / "tokenizer")
    assert "tokens" not in constructions[0]


def test_streaming_zipformer_loads_via_online_recognizer(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    catalog_model = _catalog(
        "streaming_zipformer",
        required_files=("encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"),
    )
    root = _model_root(tmp_path, catalog_model)
    constructions: list[dict[str, object]] = []
    _fake_recognizer_module(
        "from_transducer", constructions, monkeypatch, attr_name="OnlineRecognizer"
    )
    monkeypatch.setattr(
        "app.models.sherpa_onnx.importlib.util.find_spec",
        lambda _: importlib.machinery.ModuleSpec("sherpa_onnx", loader=None),
    )

    SherpaOnnxEngine(root, catalog_model)._load_recognizer_sync()

    assert constructions[0]["encoder"] == str(root / "encoder.onnx")
    assert constructions[0]["decoder"] == str(root / "decoder.onnx")
    assert constructions[0]["joiner"] == str(root / "joiner.onnx")
    assert constructions[0]["tokens"] == str(root / "tokens.txt")
    assert constructions[0]["enable_endpoint_detection"] is True


async def test_create_stream_wraps_the_recognizers_stream(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    catalog_model = _catalog(
        "streaming_zipformer",
        required_files=("encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"),
    )
    root = _model_root(tmp_path, catalog_model)
    raw_stream = object()

    class Recognizer:
        @classmethod
        def from_transducer(cls, **kwargs: object) -> Recognizer:
            return cls()

        def create_stream(self) -> object:
            return raw_stream

    module = types.ModuleType("sherpa_onnx")
    module.OnlineRecognizer = Recognizer  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "sherpa_onnx", module)
    monkeypatch.setattr(
        "app.models.sherpa_onnx.importlib.util.find_spec",
        lambda _: importlib.machinery.ModuleSpec("sherpa_onnx", loader=None),
    )

    engine = SherpaOnnxEngine(root, catalog_model)
    adapter = await engine.create_stream()

    assert isinstance(adapter, _SherpaOnnxStreamAdapter)
    assert adapter._stream is raw_stream


def test_every_shipped_sherpa_model_type_has_a_loader(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A new catalog entry must not reach users before its engine branch exists."""
    from app.catalog import DEFAULT_CATALOG, ENGINE_SHERPA_ONNX

    class Recognizer:
        def __getattr__(self, name: str) -> object:
            raise AttributeError(name)

    def make_module() -> types.ModuleType:
        module = types.ModuleType("sherpa_onnx")

        class Any_:
            def __getattr__(self, name: str) -> object:
                return lambda **kwargs: Recognizer()

            def __call__(self, **kwargs: object) -> Recognizer:
                return Recognizer()

        module.OfflineRecognizer = Any_()  # type: ignore[attr-defined]
        module.OnlineRecognizer = Any_()  # type: ignore[attr-defined]
        return module

    monkeypatch.setitem(sys.modules, "sherpa_onnx", make_module())
    monkeypatch.setattr(
        "app.models.sherpa_onnx.importlib.util.find_spec",
        lambda _: importlib.machinery.ModuleSpec("sherpa_onnx", loader=None),
    )

    shipped = [model for model in DEFAULT_CATALOG if model.engine == ENGINE_SHERPA_ONNX]
    assert shipped, "expected sherpa-onnx entries in the default catalog"
    for model in shipped:
        root = _model_root(tmp_path, model)
        SherpaOnnxEngine(root, model)._load_recognizer_sync()


def test_sherpa_rejects_unknown_model_type(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    catalog_model = _catalog("not_a_real_engine", required_files=("tokens.txt",))
    root = _model_root(tmp_path, catalog_model)
    monkeypatch.setitem(sys.modules, "sherpa_onnx", types.ModuleType("sherpa_onnx"))

    with pytest.raises(EngineUnavailableError, match="Unsupported sherpa-onnx model type"):
        SherpaOnnxEngine(root, catalog_model)._load_recognizer_sync()


async def test_sherpa_rejects_unsupported_language(tmp_path: Path) -> None:
    catalog_model = _catalog()
    engine = SherpaOnnxEngine(_model_root(tmp_path, catalog_model), catalog_model)

    # The specific subclass, not just the base: the API layer keys the
    # `language_unsupported` code off it, and the clients key Retry off that code.
    with pytest.raises(LanguageUnsupportedError, match="does not support es"):
        await engine.transcribe(
            tmp_path / "unused.wav",
            TranscriptionOptions("es", "casual"),
        )


def test_decode_wave_online_reads_result_from_the_recognizer(tmp_path: Path) -> None:
    from app.models.sherpa_onnx import _decode_wave_online

    audio = tmp_path / "audio.wav"
    _wave(audio)

    class FakeStream:
        def __init__(self) -> None:
            self.waveform: tuple[int, list[float]] | None = None
            self.finished = False

        def accept_waveform(self, sample_rate: int, samples: list[float]) -> None:
            self.waveform = (sample_rate, samples)

        def input_finished(self) -> None:
            self.finished = True

    class FakeRecognizer:
        def __init__(self) -> None:
            self.stream = FakeStream()
            self.ready_calls = 0

        def create_stream(self) -> FakeStream:
            return self.stream

        def is_ready(self, stream: FakeStream) -> bool:
            self.ready_calls += 1
            return self.ready_calls == 1

        def decode_stream(self, stream: FakeStream) -> None:
            pass

        def get_result(self, stream: FakeStream) -> str:
            # OnlineRecognizer.get_result returns a plain str, unlike the
            # offline result objects, which expose `.text`.
            return " final streaming text "

    recognizer = FakeRecognizer()
    text = _decode_wave_online(recognizer, audio)

    assert text == "final streaming text"
    assert recognizer.stream.finished is True
    assert recognizer.stream.waveform is not None


def test_supports_streaming_only_for_the_streaming_model_type(tmp_path: Path) -> None:
    streaming_model = _catalog(
        "streaming_zipformer",
        required_files=("encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"),
    )
    batch_model = _catalog("sense_voice")

    streaming_engine = SherpaOnnxEngine(_model_root(tmp_path, streaming_model), streaming_model)
    batch_engine = SherpaOnnxEngine(_model_root(tmp_path, batch_model), batch_model)
    no_model_engine = SherpaOnnxEngine(None, None)

    assert streaming_engine.supports_streaming is True
    assert batch_engine.supports_streaming is False
    assert no_model_engine.supports_streaming is False


async def test_create_stream_rejects_a_non_streaming_model(tmp_path: Path) -> None:
    catalog_model = _catalog("sense_voice")
    engine = SherpaOnnxEngine(_model_root(tmp_path, catalog_model), catalog_model)

    with pytest.raises(EngineUnavailableError, match="does not stream"):
        await engine.create_stream()


class _FakeOnlineStream:
    def __init__(self) -> None:
        self.waveforms: list[tuple[int, list[float]]] = []
        self.finished = False

    def accept_waveform(self, sample_rate: int, samples: list[float]) -> None:
        self.waveforms.append((sample_rate, list(samples)))

    def input_finished(self) -> None:
        self.finished = True


class _FakeOnlineRecognizer:
    """Lets a test script exactly what one `is_ready`/`decode_stream` drain sees."""

    def __init__(self) -> None:
        self.ready_remaining = 0
        self.endpoint = False
        self.text = ""
        self.decode_calls = 0
        self.reset_calls = 0

    def is_ready(self, stream: object) -> bool:
        if self.ready_remaining > 0:
            self.ready_remaining -= 1
            return True
        return False

    def decode_stream(self, stream: object) -> None:
        self.decode_calls += 1

    def is_endpoint(self, stream: object) -> bool:
        return self.endpoint

    def get_result(self, stream: object) -> str:
        # OnlineRecognizer.get_result returns a plain str, unlike the offline
        # result objects, which expose `.text`.
        return self.text

    def reset(self, stream: object) -> None:
        self.reset_calls += 1
        self.text = ""
        self.endpoint = False


def test_stream_adapter_reports_partial_then_completes_a_line() -> None:
    recognizer = _FakeOnlineRecognizer()
    stream = _FakeOnlineStream()
    adapter = _SherpaOnnxStreamAdapter(recognizer, stream)
    events: list[object] = []
    adapter.add_listener(events.append)

    recognizer.ready_remaining = 1
    recognizer.text = "hello"
    adapter.add_audio([0.1, 0.2], 16_000)
    assert len(events) == 1
    assert events[0].line.text == "hello"
    assert events[0].line.line_id == 0

    recognizer.ready_remaining = 1
    recognizer.text = "hello world"
    recognizer.endpoint = True
    adapter.add_audio([0.3, 0.4], 16_000)
    assert len(events) == 2
    assert events[1].line.text == "hello world"
    assert events[1].line.line_id == 0
    assert recognizer.reset_calls == 1

    result = adapter.stop()
    assert [(line.line_id, line.text) for line in result.lines] == [(0, "hello world")]
    assert stream.finished is True


def test_stream_adapter_starts_a_new_line_after_each_endpoint() -> None:
    recognizer = _FakeOnlineRecognizer()
    stream = _FakeOnlineStream()
    adapter = _SherpaOnnxStreamAdapter(recognizer, stream)

    recognizer.ready_remaining = 1
    recognizer.text = "first segment"
    recognizer.endpoint = True
    adapter.add_audio([0.1], 16_000)

    recognizer.ready_remaining = 1
    recognizer.text = "second segment"
    recognizer.endpoint = True
    adapter.add_audio([0.2], 16_000)

    result = adapter.stop()
    assert [(line.line_id, line.text) for line in result.lines] == [
        (0, "first segment"),
        (1, "second segment"),
    ]


def test_stream_adapter_does_not_repeat_identical_partial_text() -> None:
    recognizer = _FakeOnlineRecognizer()
    stream = _FakeOnlineStream()
    adapter = _SherpaOnnxStreamAdapter(recognizer, stream)
    events: list[object] = []
    adapter.add_listener(events.append)

    recognizer.ready_remaining = 1
    recognizer.text = "hello"
    adapter.add_audio([0.1], 16_000)
    recognizer.ready_remaining = 1
    recognizer.text = "hello"  # unchanged
    adapter.add_audio([0.2], 16_000)

    assert len(events) == 1
