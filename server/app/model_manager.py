from __future__ import annotations

import asyncio
import json
import shutil
import threading
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, cast
from urllib.parse import urlparse

from app.catalog import (
    DEFAULT_CATALOG,
    ENGINE_MOONSHINE,
    ENGINE_WHISPER_CPP,
    ENGINE_WHISPERKIT,
    CatalogModel,
    catalog_by_id,
)

CHUNK_SIZE = 1024 * 1024
USER_AGENT = "localflow-gateway/0.2"
HF_BASE_URL = "https://huggingface.co"


class DownloadCancelled(Exception):
    pass


class DownloadInProgressError(Exception):
    pass


class UnknownModelError(Exception):
    pass


@dataclass(slots=True)
class DownloadState:
    model_id: str
    status: str = "downloading"  # downloading | completed | failed | cancelled
    downloaded_bytes: int = 0
    total_bytes: int | None = None
    current_file: str = ""
    error: str | None = None


@dataclass(frozen=True, slots=True)
class InstalledModel:
    id: str
    engine: str
    key: str
    path: Path
    size_bytes: int
    custom: bool = False


@dataclass(slots=True)
class _DownloadHandle:
    state: DownloadState
    cancel: threading.Event
    task: asyncio.Task[None] | None = field(default=None)


class ModelManager:
    """Downloads, lists, and deletes local speech models."""

    def __init__(
        self,
        models_dir: Path,
        catalog: tuple[CatalogModel, ...] = DEFAULT_CATALOG,
    ) -> None:
        self.models_dir = models_dir
        self.catalog = catalog
        self._by_id = catalog_by_id(catalog)
        self._downloads: dict[str, _DownloadHandle] = {}

    # ------------------------------------------------------------------ paths

    def model_path(self, model: CatalogModel) -> Path:
        return self.models_dir / model.engine / model.key

    def installed_path(self, model_id: str) -> Path | None:
        installed = {model.id: model for model in self.installed()}
        entry = installed.get(model_id)
        return entry.path if entry else None

    # --------------------------------------------------------------- listing

    def installed(self) -> list[InstalledModel]:
        results: list[InstalledModel] = []
        catalog_paths: set[Path] = set()
        for model in self.catalog:
            path = self.model_path(model)
            marker = path / model.marker_file if model.marker_file else path
            if marker.exists():
                catalog_paths.add(path)
                results.append(
                    InstalledModel(
                        id=model.id,
                        engine=model.engine,
                        key=model.key,
                        path=path,
                        size_bytes=_directory_size(path) if path.is_dir() else path.stat().st_size,
                    )
                )
        whisper_cpp_dir = self.models_dir / ENGINE_WHISPER_CPP
        if whisper_cpp_dir.is_dir():
            for file in sorted(whisper_cpp_dir.iterdir()):
                if not file.is_file() or file.suffix not in {".bin", ".gguf"}:
                    continue
                if file in catalog_paths:
                    continue
                catalog_model = self._by_key(file.name, ENGINE_WHISPER_CPP)
                model_id = catalog_model.id if catalog_model else f"custom:{file.name}"
                results.append(
                    InstalledModel(
                        id=model_id,
                        engine=ENGINE_WHISPER_CPP,
                        key=file.name,
                        path=file,
                        size_bytes=file.stat().st_size,
                        custom=catalog_model is None,
                    )
                )
        whisperkit_dir = self.models_dir / ENGINE_WHISPERKIT
        if whisperkit_dir.is_dir():
            for folder in sorted(whisperkit_dir.iterdir()):
                if not folder.is_dir() or not (folder / "config.json").is_file():
                    continue
                if folder in catalog_paths:
                    continue
                catalog_model = self._by_key(folder.name, ENGINE_WHISPERKIT)
                model_id = catalog_model.id if catalog_model else f"custom:{folder.name}"
                results.append(
                    InstalledModel(
                        id=model_id,
                        engine=ENGINE_WHISPERKIT,
                        key=folder.name,
                        path=folder,
                        size_bytes=_directory_size(folder),
                        custom=catalog_model is None,
                    )
                )
        return results

    def downloads(self) -> list[DownloadState]:
        return [handle.state for handle in self._downloads.values()]

    def download_state(self, model_id: str) -> DownloadState | None:
        handle = self._downloads.get(model_id)
        return handle.state if handle else None

    # ------------------------------------------------------------- downloads

    def start_download(self, model_id: str) -> DownloadState:
        model = self._by_id.get(model_id)
        if model is None:
            raise UnknownModelError(model_id)
        return self._start(model_id, lambda handle: self._run_catalog_download(model, handle))

    def start_custom_download(self, url: str) -> DownloadState:
        filename = _validate_custom_url(url)
        model_id = f"custom:{filename}"
        if self.installed_path(model_id) is not None:
            raise DownloadInProgressError(f"{filename} is already installed.")
        destination = self.models_dir / ENGINE_WHISPER_CPP / filename
        return self._start(
            model_id,
            lambda handle: self._run_single_file(url, destination, handle),
        )

    def cancel_download(self, model_id: str) -> bool:
        handle = self._downloads.get(model_id)
        if handle is None or handle.state.status != "downloading":
            return False
        handle.cancel.set()
        return True

    def delete(self, model_id: str) -> bool:
        handle = self._downloads.get(model_id)
        if handle is not None and handle.state.status == "downloading":
            raise DownloadInProgressError(model_id)
        path = self._path_for_id(model_id)
        if path is None or not path.exists():
            return False
        self._downloads.pop(model_id, None)
        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink()
        return True

    # ----------------------------------------------------------------- inner

    def _start(
        self,
        model_id: str,
        runner: Any,
    ) -> DownloadState:
        existing = self._downloads.get(model_id)
        if existing is not None and existing.state.status == "downloading":
            raise DownloadInProgressError(model_id)
        handle = _DownloadHandle(state=DownloadState(model_id=model_id), cancel=threading.Event())
        self._downloads[model_id] = handle
        handle.task = asyncio.create_task(self._guarded(model_id, runner, handle))
        return handle.state

    async def _guarded(self, model_id: str, runner: Any, handle: _DownloadHandle) -> None:
        try:
            await runner(handle)
        except DownloadCancelled:
            handle.state.status = "cancelled"
        except Exception as error:  # noqa: BLE001 - surfaced through the API
            handle.state.status = "failed"
            handle.state.error = str(error)[:300]

    async def _run_catalog_download(self, model: CatalogModel, handle: _DownloadHandle) -> None:
        if model.engine == ENGINE_MOONSHINE:
            await self._run_moonshine_download(model, handle)
            return
        if model.huggingface_repo is not None:
            await self._run_huggingface_download(model, handle)
            return
        if model.download_url is None:
            raise UnknownModelError(model.id)
        await self._run_single_file(model.download_url, self.model_path(model), handle)

    async def _run_moonshine_download(self, model: CatalogModel, handle: _DownloadHandle) -> None:
        final_dir = self.model_path(model)
        partial_dir = final_dir.with_name(final_dir.name + ".partial")
        shutil.rmtree(partial_dir, ignore_errors=True)
        partial_dir.mkdir(parents=True, exist_ok=True)
        handle.state.total_bytes = model.size_bytes
        handle.state.current_file = "Moonshine model assets"
        try:
            model_path, model_arch = await asyncio.to_thread(
                _download_moonshine_model, model.key, partial_dir
            )
            if handle.cancel.is_set():
                raise DownloadCancelled
            relative_path = Path(model_path).resolve().relative_to(partial_dir.resolve())
            metadata = {
                "language": model.key,
                "model_path": str(relative_path),
                "model_arch": int(model_arch),
            }
            (partial_dir / ".localflow-model.json").write_text(
                json.dumps(metadata, indent=2) + "\n", encoding="utf-8"
            )
            handle.state.downloaded_bytes = _directory_size(partial_dir)
            final_dir.parent.mkdir(parents=True, exist_ok=True)
            shutil.rmtree(final_dir, ignore_errors=True)
            partial_dir.replace(final_dir)
            handle.state.status = "completed"
        finally:
            if handle.state.status != "completed":
                shutil.rmtree(partial_dir, ignore_errors=True)

    async def _run_single_file(self, url: str, destination: Path, handle: _DownloadHandle) -> None:
        destination.parent.mkdir(parents=True, exist_ok=True)
        partial = destination.with_name(destination.name + ".partial")
        try:
            await asyncio.to_thread(_download_file, url, partial, handle.state, handle.cancel, "")
            if handle.cancel.is_set():
                raise DownloadCancelled
            partial.replace(destination)
            handle.state.status = "completed"
        finally:
            if handle.state.status != "completed":
                partial.unlink(missing_ok=True)

    async def _run_huggingface_download(self, model: CatalogModel, handle: _DownloadHandle) -> None:
        if not model.huggingface_repo or model.huggingface_folder is None:
            raise UnknownModelError(model.id)
        files = await asyncio.to_thread(
            _list_repo_folder, model.huggingface_repo, model.huggingface_folder
        )
        if not files:
            raise UnknownModelError(f"No model files found in {model.huggingface_repo}.")
        handle.state.total_bytes = sum(size for _, size in files)
        final_dir = self.model_path(model)
        partial_dir = final_dir.with_name(final_dir.name + ".partial")
        shutil.rmtree(partial_dir, ignore_errors=True)
        partial_dir.mkdir(parents=True, exist_ok=True)
        try:
            for relative, _ in files:
                if handle.cancel.is_set():
                    raise DownloadCancelled
                url = (
                    f"{HF_BASE_URL}/{model.huggingface_repo}"
                    f"/resolve/main/{_repo_path(model.huggingface_folder, relative)}"
                )
                await asyncio.to_thread(
                    _download_file,
                    url,
                    partial_dir / relative,
                    handle.state,
                    handle.cancel,
                    relative,
                )
            if handle.cancel.is_set():
                raise DownloadCancelled
            final_dir.parent.mkdir(parents=True, exist_ok=True)
            shutil.rmtree(final_dir, ignore_errors=True)
            partial_dir.replace(final_dir)
            handle.state.status = "completed"
        finally:
            if handle.state.status != "completed":
                shutil.rmtree(partial_dir, ignore_errors=True)

    def _by_key(self, key: str, engine: str) -> CatalogModel | None:
        for model in self.catalog:
            if model.key == key and model.engine == engine:
                return model
        return None

    def _path_for_id(self, model_id: str) -> Path | None:
        model = self._by_id.get(model_id)
        if model is not None:
            return self.model_path(model)
        if model_id.startswith("custom:"):
            name = model_id[len("custom:") :]
            if Path(name).name != name or not name:
                return None
            if name.endswith((".bin", ".gguf")):
                return self.models_dir / ENGINE_WHISPER_CPP / name
            return self.models_dir / ENGINE_WHISPERKIT / name
        return None


def _validate_custom_url(url: str) -> str:
    parsed = urlparse(url)
    if parsed.scheme != "https":
        raise ValueError("Only HTTPS URLs are supported.")
    filename = Path(parsed.path).name
    if not filename.endswith((".bin", ".gguf")):
        raise ValueError("Custom models must be .bin or .gguf files.")
    return filename


def _list_repo_folder(repo: str, folder: str) -> list[tuple[str, int]]:
    tree_path = f"/{folder}" if folder else ""
    url = f"{HF_BASE_URL}/api/models/{repo}/tree/main{tree_path}?recursive=true&expand=false"
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=30) as response:
        payload: list[dict[str, Any]] = json.load(response)
    files: list[tuple[str, int]] = []
    prefix = f"{folder}/" if folder else ""
    for entry in payload:
        if entry.get("type") != "file":
            continue
        path = str(entry.get("path", ""))
        if not path.startswith(prefix):
            continue
        files.append((path[len(prefix) :], int(entry.get("size") or 0)))
    return files


def _repo_path(folder: str, relative: str) -> str:
    return f"{folder}/{relative}" if folder else relative


def _download_file(
    url: str,
    destination: Path,
    state: DownloadState,
    cancel: threading.Event,
    display_name: str,
) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=60) as response:
        length = response.headers.get("Content-Length")
        if state.total_bytes is None and length and length.isdigit():
            state.total_bytes = int(length)
        destination.parent.mkdir(parents=True, exist_ok=True)
        state.current_file = display_name or destination.name
        with destination.open("wb") as output:
            while True:
                if cancel.is_set():
                    raise DownloadCancelled
                chunk = response.read(CHUNK_SIZE)
                if not chunk:
                    break
                output.write(chunk)
                state.downloaded_bytes += len(chunk)


def _directory_size(path: Path) -> int:
    return sum(file.stat().st_size for file in path.rglob("*") if file.is_file())


def _download_moonshine_model(language: str, cache_root: Path) -> tuple[str, Any]:
    try:
        from moonshine_voice import get_model_for_language  # type: ignore[import-not-found]
    except ImportError as error:
        raise RuntimeError(
            "Moonshine support is not installed. Install localflow-gateway[engines]."
        ) from error
    return cast(tuple[str, Any], get_model_for_language(language, cache_root=cache_root))
