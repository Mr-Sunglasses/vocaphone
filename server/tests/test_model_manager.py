from __future__ import annotations

import asyncio
import dataclasses
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
    assert (
        entries["faster-whisper:distil-medium.en"].huggingface_repo
        == "Systran/faster-distil-whisper-medium.en"
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
