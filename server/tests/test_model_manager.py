from __future__ import annotations

import asyncio
import dataclasses
import io
import tarfile
from pathlib import Path

import pytest

from app import model_manager
from app.catalog import DEFAULT_CATALOG, CatalogModel
from app.model_manager import (
    DownloadInProgressError,
    ModelManager,
    UnknownModelError,
)

TINY_FILE = CatalogModel(
    id="whisper.cpp:ggml-tiny.bin",
    engine="whisper.cpp",
    key="ggml-tiny.bin",
    label="Test Tiny",
    size_bytes=11,
    languages="Multilingual",
    quality="Fastest",
    minimum_ram_gb=4,
    download_url=None,  # filled by fixture
)

TINY_FOLDER = CatalogModel(
    id="whisperkit:openai_whisper-tiny",
    engine="whisperkit",
    key="openai_whisper-tiny",
    label="Test WhisperKit Tiny",
    size_bytes=30,
    languages="Multilingual",
    quality="Fastest",
    minimum_ram_gb=4,
    huggingface_repo="example/repo",
    huggingface_folder="openai_whisper-tiny",
)

TINY_CTRANSLATE = CatalogModel(
    id="faster-whisper:tiny.en",
    engine="faster-whisper",
    key="tiny.en",
    label="Test faster-whisper Tiny EN",
    size_bytes=30,
    languages="English only",
    quality="Fastest",
    minimum_ram_gb=2,
    huggingface_repo="example/faster-repo",
    huggingface_folder="",
    marker_file="model.bin",
)

MOONSHINE_SPANISH = CatalogModel(
    id="moonshine:es",
    engine="moonshine",
    key="es",
    label="Moonshine Spanish",
    size_bytes=65_000_000,
    languages="Spanish only",
    quality="Fast",
    minimum_ram_gb=2,
    marker_file=".vocaphone-model.json",
    language_code="es",
    model_arch=1,
)

SHERPA_TEST = CatalogModel(
    id="sherpa-onnx:test-int8",
    engine="sherpa-onnx",
    key="test-int8",
    label="Test sherpa model",
    size_bytes=30,
    languages="English only",
    quality="Fast",
    minimum_ram_gb=2,
    marker_file=".vocaphone-model.json",
    archive_root="published-model",
    required_files=("model.int8.onnx", "tokens.txt"),
    model_type="sense_voice",
    language_codes=("en",),
)


def test_catalog_includes_standalone_handy_compatible_models() -> None:
    entries = {model.key: model for model in DEFAULT_CATALOG}

    assert entries["whisper-medium-q4_1.bin"].engine == "whisper.cpp"
    assert entries["ggml-large-v3-q5_0.bin"].source == "Handy-compatible"
    assert entries["breeze-asr-q5_k.bin"].family == "Breeze ASR"


def test_distilled_faster_whisper_uses_published_repository_names() -> None:
    entries = {model.id: model for model in DEFAULT_CATALOG}

    assert (
        entries["faster-whisper:distil-small.en"].huggingface_repo
        == "Systran/faster-distil-whisper-small.en"
    )


def test_catalog_includes_all_moonshine_languages_and_english_tiers() -> None:
    entries = {model.id: model for model in DEFAULT_CATALOG}

    assert {entry.language_code for entry in entries.values() if entry.engine == "moonshine"} == {
        "ar",
        "en",
        "es",
        "ja",
        "ko",
        "uk",
        "vi",
        "zh",
    }
    assert entries["moonshine:en"].model_arch == 5
    assert entries["moonshine:en-tiny-streaming"].supports_streaming is True
    assert entries["moonshine:es"].supports_streaming is False
    assert entries["moonshine:es"].commercial_use is False
    assert (
        entries["faster-whisper:distil-medium.en"].huggingface_repo
        == "Systran/faster-distil-whisper-medium.en"
    )


def test_catalog_includes_portable_and_apple_silicon_models() -> None:
    entries = {model.id: model for model in DEFAULT_CATALOG}

    sensevoice = entries["sherpa-onnx:sensevoice-small-int8"]
    assert sensevoice.required_files == ("model.int8.onnx", "tokens.txt")
    assert sensevoice.language_codes == ("zh", "yue", "en", "ja", "ko")
    assert sensevoice.apple_silicon_only is False

    parakeet = entries["sherpa-onnx:parakeet-tdt-0.6b-v3-int8"]
    assert parakeet.model_type == "nemo_transducer"
    assert parakeet.license_name == "CC BY 4.0"

    mlx_turbo = entries["mlx-audio:whisper-large-v3-turbo-4bit"]
    assert mlx_turbo.apple_silicon_only is True
    assert mlx_turbo.marker_file == "model.safetensors"


def test_catalog_includes_gigaam_and_canary_models() -> None:
    entries = {model.id: model for model in DEFAULT_CATALOG}

    gigaam_ctc = entries["sherpa-onnx:gigaam-v3-ctc-russian-int8"]
    assert gigaam_ctc.archive_url is None
    assert (
        gigaam_ctc.huggingface_repo
        == "csukuangfj/sherpa-onnx-nemo-ctc-giga-am-v3-russian-2025-12-16"
    )
    assert gigaam_ctc.required_files == ("model.int8.onnx", "tokens.txt")
    assert gigaam_ctc.model_type == "nemo_ctc"
    assert gigaam_ctc.language_codes == ("ru",)
    assert gigaam_ctc.license_name == "MIT"

    gigaam_rnnt = entries["sherpa-onnx:gigaam-v3-rnnt-russian-int8"]
    assert gigaam_rnnt.huggingface_repo == (
        "csukuangfj/sherpa-onnx-nemo-transducer-giga-am-v3-russian-2025-12-16"
    )
    assert gigaam_rnnt.required_files == (
        "encoder.int8.onnx",
        "decoder.onnx",
        "joiner.onnx",
        "tokens.txt",
    )
    assert gigaam_rnnt.model_type == "nemo_transducer"
    assert gigaam_rnnt.license_name == "MIT"

    canary = entries["sherpa-onnx:canary-180m-flash-en-int8"]
    assert (
        canary.huggingface_repo == "csukuangfj/sherpa-onnx-nemo-canary-180m-flash-en-es-de-fr-int8"
    )
    assert canary.required_files == ("encoder.int8.onnx", "decoder.int8.onnx", "tokens.txt")
    assert canary.model_type == "nemo_canary"
    assert canary.language_codes == ("en",)
    assert canary.license_name == "CC BY 4.0"

    streaming = entries["sherpa-onnx:streaming-zipformer-en-20m-int8"]
    assert (
        streaming.huggingface_repo == "csukuangfj/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17"
    )
    assert streaming.required_files == (
        "encoder-epoch-99-avg-1.int8.onnx",
        "decoder-epoch-99-avg-1.int8.onnx",
        "joiner-epoch-99-avg-1.int8.onnx",
        "tokens.txt",
    )
    assert streaming.model_type == "streaming_zipformer"
    assert streaming.supports_streaming is True
    assert streaming.license_name == "Apache 2.0"


def test_catalog_includes_the_newer_sherpa_families() -> None:
    entries = {model.id: model for model in DEFAULT_CATALOG}

    dolphin = entries["sherpa-onnx:dolphin-small-ctc-int8"]
    assert dolphin.model_type == "dolphin_ctc"
    assert dolphin.required_files == ("model.int8.onnx", "tokens.txt")
    # The only South Asian coverage in the catalog.
    assert {"hi", "bn", "ta", "ur"} <= set(dolphin.language_codes)
    assert entries["sherpa-onnx:dolphin-base-ctc-int8"].language_codes == dolphin.language_codes

    qwen3 = entries["sherpa-onnx:qwen3-asr-0.6b-int8"]
    assert qwen3.model_type == "qwen3_asr"
    assert "tokenizer/vocab.json" in qwen3.required_files
    assert "tokens.txt" not in qwen3.required_files

    parakeet_v2 = entries["sherpa-onnx:parakeet-tdt-0.6b-v2-int8"]
    assert parakeet_v2.model_type == "nemo_transducer"
    assert parakeet_v2.language_codes == ("en",)


def test_catalog_includes_the_newer_apple_silicon_models() -> None:
    entries = {model.id: model for model in DEFAULT_CATALOG}

    for model_id, repository in (
        ("mlx-audio:parakeet-tdt-0.6b-v2", "mlx-community/parakeet-tdt-0.6b-v2"),
        ("mlx-audio:qwen3-asr-0.6b-4bit", "mlx-community/Qwen3-ASR-0.6B-4bit"),
        ("mlx-audio:qwen3-asr-1.7b-4bit", "mlx-community/Qwen3-ASR-1.7B-4bit"),
        ("mlx-audio:granite-speech-4.1-2b-nar", "mlx-community/granite-speech-4.1-2b-nar-mlx-5bit"),
    ):
        model = entries[model_id]
        assert model.huggingface_repo == repository
        assert model.apple_silicon_only is True
        assert model.marker_file == "model.safetensors"
        assert model.huggingface_folder == ""


def test_every_catalog_model_has_a_download_mechanism() -> None:
    for model in DEFAULT_CATALOG:
        if model.engine == "moonshine":
            assert model.language_code, f"{model.id} needs a language for the Moonshine downloader"
            continue
        mechanism = (
            model.archive_url is not None
            or model.huggingface_repo is not None
            or model.download_url is not None
        )
        assert mechanism, f"{model.id} has no way to be downloaded"
        if model.archive_url is not None:
            assert model.archive_root, f"{model.id} has an archive_url but no archive_root"
        if model.engine == "sherpa-onnx":
            assert model.required_files, f"{model.id} must name the files it needs"
            assert model.model_type, f"{model.id} must declare a model_type"


def test_sherpa_onnx_helper_requires_a_download_mechanism() -> None:
    from app.catalog import _sherpa_onnx

    with pytest.raises(ValueError, match="archive_url/archive_root or huggingface_repo"):
        _sherpa_onnx(
            "broken",
            "Broken",
            1,
            "English",
            "Fast",
            1,
            required_files=("model.onnx",),
            model_type="nemo_ctc",
            language_codes=("en",),
            family="Broken",
            description="",
            license_name="MIT",
        )


@pytest.fixture
def tiny_file_model(tmp_path: Path) -> CatalogModel:
    source = tmp_path / "source.bin"
    source.write_bytes(b"hello model")
    return dataclasses.replace(TINY_FILE, download_url=source.as_uri())


@pytest.fixture
def manager(tmp_path: Path, tiny_file_model: CatalogModel) -> ModelManager:
    return ModelManager(
        tmp_path / "models", catalog=(tiny_file_model, TINY_FOLDER, TINY_CTRANSLATE)
    )


def test_installed_scans_both_engines(manager: ModelManager) -> None:
    whisper_dir = manager.models_dir / "whisper.cpp"
    whisper_dir.mkdir(parents=True)
    (whisper_dir / "ggml-tiny.bin").write_bytes(b"abc")
    (whisper_dir / "strange.gguf").write_bytes(b"custom-bytes")
    kit_dir = manager.models_dir / "whisperkit" / "openai_whisper-tiny"
    (kit_dir / "AudioEncoder.mlmodelc" / "weights").mkdir(parents=True)
    (kit_dir / "config.json").write_text("{}")
    (kit_dir / "AudioEncoder.mlmodelc" / "weights" / "weight.bin").write_bytes(b"xx")
    (manager.models_dir / "whisperkit" / "incomplete").mkdir()

    installed = {model.id: model for model in manager.installed()}

    assert set(installed) == {
        "whisper.cpp:ggml-tiny.bin",
        "custom:strange.gguf",
        "whisperkit:openai_whisper-tiny",
    }
    assert installed["custom:strange.gguf"].custom is True
    assert installed["whisperkit:openai_whisper-tiny"].size_bytes == 4


async def test_download_installs_single_file(manager: ModelManager) -> None:
    state = manager.start_download("whisper.cpp:ggml-tiny.bin")
    assert state.status == "downloading"
    await asyncio.wait_for(_wait_finished(manager, "whisper.cpp:ggml-tiny.bin"), timeout=5)

    assert state.status == "completed"
    assert state.downloaded_bytes == 11
    installed = manager.installed_path("whisper.cpp:ggml-tiny.bin")
    assert installed is not None
    assert installed.read_bytes() == b"hello model"


async def test_download_unknown_model_raises(manager: ModelManager) -> None:
    with pytest.raises(UnknownModelError):
        manager.start_download("whisper.cpp:nope.bin")


async def test_double_download_rejected(manager: ModelManager) -> None:
    manager.start_download("whisper.cpp:ggml-tiny.bin")
    with pytest.raises(DownloadInProgressError):
        manager.start_download("whisper.cpp:ggml-tiny.bin")
    await asyncio.wait_for(_wait_finished(manager, "whisper.cpp:ggml-tiny.bin"), timeout=5)


async def test_whisperkit_folder_download(
    manager: ModelManager, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    mirror = tmp_path / "mirror"
    folder = mirror / "example/repo/resolve/main/openai_whisper-tiny"
    (folder / "AudioEncoder.mlmodelc").mkdir(parents=True)
    (folder / "config.json").write_text("{}")
    (folder / "AudioEncoder.mlmodelc" / "model.mil").write_text("mil")
    monkeypatch.setattr(model_manager, "HF_BASE_URL", mirror.as_uri())
    monkeypatch.setattr(
        model_manager,
        "_list_repo_folder",
        lambda repo, name: [("config.json", 2), ("AudioEncoder.mlmodelc/model.mil", 3)],
    )

    state = manager.start_download("whisperkit:openai_whisper-tiny")
    await asyncio.wait_for(_wait_finished(manager, "whisperkit:openai_whisper-tiny"), timeout=5)

    assert state.status == "completed"
    assert state.total_bytes == 5
    installed = manager.installed_path("whisperkit:openai_whisper-tiny")
    assert installed is not None
    assert (installed / "config.json").is_file()
    assert (installed / "AudioEncoder.mlmodelc" / "model.mil").is_file()
    assert not (manager.models_dir / "whisperkit" / "openai_whisper-tiny.partial").exists()


async def test_root_huggingface_folder_download(
    manager: ModelManager, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    mirror = tmp_path / "mirror"
    folder = mirror / "example/faster-repo/resolve/main"
    folder.mkdir(parents=True)
    (folder / "config.json").write_text("{}")
    (folder / "model.bin").write_bytes(b"model")
    monkeypatch.setattr(model_manager, "HF_BASE_URL", mirror.as_uri())
    monkeypatch.setattr(
        model_manager,
        "_list_repo_folder",
        lambda repo, name: [("config.json", 2), ("model.bin", 5)],
    )

    state = manager.start_download("faster-whisper:tiny.en")
    await asyncio.wait_for(_wait_finished(manager, "faster-whisper:tiny.en"), timeout=5)

    assert state.status == "completed"
    installed = manager.installed_path("faster-whisper:tiny.en")
    assert installed is not None
    assert (installed / "model.bin").read_bytes() == b"model"


async def test_moonshine_download_uses_catalog_language_and_architecture(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    manager = ModelManager(tmp_path / "models", catalog=(MOONSHINE_SPANISH,))
    requested: dict[str, object] = {}

    def fake_download(language: str, model_arch: int, cache_root: Path) -> tuple[str, int]:
        requested.update(language=language, model_arch=model_arch)
        model_path = cache_root / "downloaded-model"
        model_path.mkdir()
        (model_path / "weights.bin").write_bytes(b"model")
        return str(model_path), model_arch

    monkeypatch.setattr(model_manager, "_download_moonshine_model", fake_download)

    state = manager.start_download("moonshine:es")
    await asyncio.wait_for(_wait_finished(manager, "moonshine:es"), timeout=5)

    assert state.status == "completed"
    assert requested == {"language": "es", "model_arch": 1}
    installed = manager.installed_path("moonshine:es")
    assert installed is not None
    metadata = (installed / ".vocaphone-model.json").read_text(encoding="utf-8")
    assert '"model_id": "moonshine:es"' in metadata
    assert '"language": "es"' in metadata


async def test_archive_download_extracts_validated_model(tmp_path: Path) -> None:
    source = tmp_path / "model.tar.bz2"
    content = tmp_path / "published-model"
    content.mkdir()
    (content / "model.int8.onnx").write_bytes(b"onnx")
    (content / "tokens.txt").write_text("token")
    with tarfile.open(source, "w:bz2") as archive:
        archive.add(content, arcname="published-model")
    catalog_model = dataclasses.replace(SHERPA_TEST, archive_url=source.as_uri())
    manager = ModelManager(tmp_path / "models", catalog=(catalog_model,))

    state = manager.start_download(catalog_model.id)
    await asyncio.wait_for(_wait_finished(manager, catalog_model.id), timeout=5)

    assert state.status == "completed"
    installed = manager.installed_path(catalog_model.id)
    assert installed is not None
    assert (installed / "model.int8.onnx").read_bytes() == b"onnx"
    metadata = (installed / ".vocaphone-model.json").read_text(encoding="utf-8")
    assert '"model_type": "sense_voice"' in metadata
    assert '"language_codes": [' in metadata
    assert not (manager.models_dir / "sherpa-onnx" / "test-int8.download").exists()


async def test_sherpa_huggingface_download_fetches_only_required_files(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    catalog_model = dataclasses.replace(
        SHERPA_TEST,
        id="sherpa-onnx:gigaam-test",
        key="gigaam-test",
        archive_url=None,
        archive_root=None,
        huggingface_repo="example/gigaam-repo",
        required_files=("model.int8.onnx", "tokens.txt"),
        model_type="nemo_ctc",
    )
    manager = ModelManager(tmp_path / "models", catalog=(catalog_model,))

    mirror = tmp_path / "mirror"
    folder = mirror / "example/gigaam-repo/resolve/main"
    folder.mkdir(parents=True)
    (folder / "model.int8.onnx").write_bytes(b"onnx-bytes")
    (folder / "tokens.txt").write_text("token")
    (folder / "README.md").write_text("not needed")
    monkeypatch.setattr(model_manager, "HF_BASE_URL", mirror.as_uri())
    monkeypatch.setattr(
        model_manager,
        "_list_repo_folder",
        lambda repo, name: [
            ("model.int8.onnx", 10),
            ("tokens.txt", 5),
            ("README.md", 999),
        ],
    )

    state = manager.start_download(catalog_model.id)
    await asyncio.wait_for(_wait_finished(manager, catalog_model.id), timeout=5)

    assert state.status == "completed"
    assert state.total_bytes == 15  # only required_files counted, not README.md
    installed = manager.installed_path(catalog_model.id)
    assert installed is not None
    assert (installed / "model.int8.onnx").read_bytes() == b"onnx-bytes"
    assert not (installed / "README.md").exists()
    metadata = (installed / ".vocaphone-model.json").read_text(encoding="utf-8")
    assert '"model_type": "nemo_ctc"' in metadata
    assert not (manager.models_dir / "sherpa-onnx" / "gigaam-test.partial").exists()


def test_archive_extractor_rejects_parent_paths(tmp_path: Path) -> None:
    archive_path = tmp_path / "unsafe.tar.bz2"
    with tarfile.open(archive_path, "w:bz2") as archive:
        member = tarfile.TarInfo("../escaped.txt")
        payload = b"unsafe"
        member.size = len(payload)
        archive.addfile(member, io.BytesIO(payload))

    with pytest.raises(RuntimeError, match="unsafe path"):
        model_manager._safe_extract_archive(archive_path, tmp_path / "extract")

    assert not (tmp_path / "escaped.txt").exists()


async def test_custom_download_validates_url(manager: ModelManager) -> None:
    with pytest.raises(ValueError, match="HTTPS"):
        manager.start_custom_download("http://example.com/model.bin")
    with pytest.raises(ValueError, match=".bin or .gguf"):
        manager.start_custom_download("https://example.com/model.txt")


async def test_custom_download_and_delete(
    manager: ModelManager, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    source = tmp_path / "my-model.gguf"
    source.write_bytes(b"custom")
    # file:// URLs stand in for HTTPS in tests; validation is covered separately.
    monkeypatch.setattr(model_manager, "_validate_custom_url", lambda url: "my-model.gguf")
    state = manager.start_custom_download(source.as_uri())
    assert state.model_id == "custom:my-model.gguf"
    await asyncio.wait_for(_wait_finished(manager, "custom:my-model.gguf"), timeout=5)
    assert manager.installed_path("custom:my-model.gguf") is not None

    assert manager.delete("custom:my-model.gguf") is True
    assert manager.installed_path("custom:my-model.gguf") is None


async def test_delete_removes_folder(manager: ModelManager) -> None:
    kit_dir = manager.models_dir / "whisperkit" / "openai_whisper-tiny"
    kit_dir.mkdir(parents=True)
    (kit_dir / "config.json").write_text("{}")
    assert manager.delete("whisperkit:openai_whisper-tiny") is True
    assert not kit_dir.exists()
    assert manager.delete("whisperkit:openai_whisper-tiny") is False


async def _wait_finished(manager: ModelManager, model_id: str) -> None:
    while True:
        state = manager.download_state(model_id)
        assert state is not None
        if state.status != "downloading":
            return
        await asyncio.sleep(0.01)
