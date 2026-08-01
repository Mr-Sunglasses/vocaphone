from __future__ import annotations

from pathlib import Path
from typing import Protocol

from app.catalog import (
    ENGINE_FASTER_WHISPER,
    ENGINE_MOONSHINE,
    ENGINE_WHISPER_CPP,
    ENGINE_WHISPERKIT,
)
from app.config import Settings
from app.model_manager import ModelManager
from app.models.base import EngineHealth, TranscriptionEngine
from app.models.faster_whisper import FasterWhisperEngine
from app.models.handy import HandyEngine
from app.models.moonshine import MoonshineEngine
from app.models.whisper_cpp import WhisperCppEngine
from app.models.whisperkit import WhisperKitEngine
from app.runtime_config import VALID_ENGINES, RuntimeConfig


class EngineProvider(Protocol):
    def current(self) -> TranscriptionEngine: ...


class StaticEngineProvider:
    """Wraps a fixed engine (used by tests and the cleanup CLI)."""

    def __init__(self, engine: TranscriptionEngine) -> None:
        self._engine = engine

    def current(self) -> TranscriptionEngine:
        return self._engine


def close_engine(engine: TranscriptionEngine) -> None:
    """Release optional persistent resources owned by an engine."""
    close = getattr(engine, "close", None)
    if callable(close):
        close()


class EngineManager:
    """Builds and hot-swaps transcription engines from WebUI choices."""

    def __init__(
        self,
        settings: Settings,
        runtime_config: RuntimeConfig,
        config_path: Path,
        model_manager: ModelManager,
    ) -> None:
        self.settings = settings
        self.runtime_config = runtime_config
        self.config_path = config_path
        self.model_manager = model_manager
        self._engine = self._build()

    def current(self) -> TranscriptionEngine:
        return self._engine

    async def health(self) -> EngineHealth:
        return await self._engine.health()

    def select_model(self, model_id: str) -> None:
        path = self.model_manager.installed_path(model_id)
        if path is None:
            raise KeyError(model_id)
        if model_id.startswith(f"{ENGINE_WHISPERKIT}:"):
            self.runtime_config.engine = ENGINE_WHISPERKIT
            self.runtime_config.whisperkit_model = str(path)
        elif model_id.startswith(f"{ENGINE_FASTER_WHISPER}:"):
            self.runtime_config.engine = ENGINE_FASTER_WHISPER
            self.runtime_config.faster_whisper_model = str(path)
        elif model_id.startswith(f"{ENGINE_MOONSHINE}:"):
            self.runtime_config.engine = ENGINE_MOONSHINE
            self.runtime_config.moonshine_language = model_id.split(":", 1)[1]
        else:
            self.runtime_config.engine = ENGINE_WHISPER_CPP
            self.runtime_config.whisper_model = str(path)
        self._apply()

    def forget_if_active(self, model_id: str) -> None:
        """Clear the model override if it points at the given model (e.g. before delete)."""
        path = self.model_manager.installed_path(model_id)
        if path is None:
            return
        changed = False
        if (
            model_id == f"{ENGINE_MOONSHINE}:{self.runtime_config.moonshine_language}"
            and self.runtime_config.engine == ENGINE_MOONSHINE
        ):
            self.runtime_config.engine = "auto"
            changed = True
        if self.runtime_config.whisper_model == str(path):
            self.runtime_config.whisper_model = None
            changed = True
        if self.runtime_config.whisperkit_model == str(path):
            self.runtime_config.whisperkit_model = None
            changed = True
        if self.runtime_config.faster_whisper_model == str(path):
            self.runtime_config.faster_whisper_model = None
            changed = True
        if changed:
            self._apply()

    def set_engine(self, engine: str) -> None:
        self.configure(
            engine,
            self.runtime_config.compute_device,
            self.runtime_config.compute_type,
            self.runtime_config.cpu_threads,
        )

    def configure(
        self,
        engine: str,
        device: str,
        compute_type: str,
        cpu_threads: int,
    ) -> None:
        """Validate and persist an engine/performance update atomically."""
        if engine not in VALID_ENGINES:
            raise ValueError(f"Engine must be one of: {', '.join(VALID_ENGINES)}.")
        if device not in {"auto", "cpu", "cuda"}:
            raise ValueError("Invalid compute device.")
        if compute_type not in {"auto", "int8", "int8_float16", "float16", "float32"}:
            raise ValueError("Invalid compute type.")
        if not 0 <= cpu_threads <= 256:
            raise ValueError("CPU threads must be between 0 and 256.")
        self.runtime_config.engine = engine
        self.runtime_config.compute_device = device
        self.runtime_config.compute_type = compute_type
        self.runtime_config.cpu_threads = cpu_threads
        if engine != ENGINE_WHISPER_CPP:
            self.runtime_config.whisper_model = None
        if engine != ENGINE_WHISPERKIT:
            self.runtime_config.whisperkit_model = None
        if engine != ENGINE_FASTER_WHISPER:
            self.runtime_config.faster_whisper_model = None
        self._apply()

    def update_performance(self, device: str, compute_type: str, cpu_threads: int) -> None:
        self.configure(self.runtime_config.engine, device, compute_type, cpu_threads)

    def _apply(self) -> None:
        self.runtime_config.save(self.config_path)
        previous = self._engine
        self._engine = self._build()
        close_engine(previous)

    def _build(self) -> TranscriptionEngine:
        return build_engine(self.settings, self.runtime_config, self.model_manager)


def build_engine(
    settings: Settings,
    runtime_config: RuntimeConfig,
    model_manager: ModelManager,
) -> TranscriptionEngine:
    engine = runtime_config.engine or settings.engine
    if engine == "handy":
        return HandyEngine(
            settings.handy_binary,
            settings.handy_model,
            fallback_model=settings.handy_fallback_model,
        )
    if engine == ENGINE_WHISPERKIT:
        return WhisperKitEngine(
            settings.whisperkit_binary,
            _whisperkit_model_path(runtime_config, model_manager),
        )
    if engine == ENGINE_FASTER_WHISPER:
        return FasterWhisperEngine(
            _faster_whisper_model_path(runtime_config, model_manager),
            device=runtime_config.compute_device,
            compute_type=runtime_config.compute_type,
            cpu_threads=runtime_config.cpu_threads,
        )
    if engine == ENGINE_MOONSHINE:
        return MoonshineEngine(
            _moonshine_model_path(runtime_config, model_manager),
            runtime_config.moonshine_language,
        )
    if engine == ENGINE_WHISPER_CPP:
        return WhisperCppEngine(
            settings.whisper_binary,
            _whisper_cpp_model_path(settings, runtime_config, model_manager),
        )
    # auto: prefer what is actually usable on this machine
    if settings.handy_binary.is_file():
        return HandyEngine(
            settings.handy_binary,
            settings.handy_model,
            fallback_model=settings.handy_fallback_model,
        )
    whisperkit_path = _whisperkit_model_path(runtime_config, model_manager)
    if whisperkit_path is not None:
        return WhisperKitEngine(settings.whisperkit_binary, whisperkit_path)
    faster_whisper_path = _faster_whisper_model_path(runtime_config, model_manager)
    if faster_whisper_path is not None:
        return FasterWhisperEngine(
            faster_whisper_path,
            device=runtime_config.compute_device,
            compute_type=runtime_config.compute_type,
            cpu_threads=runtime_config.cpu_threads,
        )
    return WhisperCppEngine(
        settings.whisper_binary,
        _whisper_cpp_model_path(settings, runtime_config, model_manager),
    )


def _whisper_cpp_model_path(
    settings: Settings,
    runtime_config: RuntimeConfig,
    model_manager: ModelManager,
) -> Path:
    if runtime_config.whisper_model:
        return Path(runtime_config.whisper_model)
    installed = [model for model in model_manager.installed() if model.engine == ENGINE_WHISPER_CPP]
    if installed:
        return max(installed, key=lambda model: model.size_bytes).path
    return settings.whisper_model


def _whisperkit_model_path(
    runtime_config: RuntimeConfig,
    model_manager: ModelManager,
) -> Path | None:
    if runtime_config.whisperkit_model:
        return Path(runtime_config.whisperkit_model)
    installed = [model for model in model_manager.installed() if model.engine == ENGINE_WHISPERKIT]
    if installed:
        return max(installed, key=lambda model: model.size_bytes).path
    return None


def _faster_whisper_model_path(
    runtime_config: RuntimeConfig,
    model_manager: ModelManager,
) -> Path | None:
    if runtime_config.faster_whisper_model:
        return Path(runtime_config.faster_whisper_model)
    installed = [
        model for model in model_manager.installed() if model.engine == ENGINE_FASTER_WHISPER
    ]
    if installed:
        return min(installed, key=lambda model: model.size_bytes).path
    return None


def _moonshine_model_path(
    runtime_config: RuntimeConfig,
    model_manager: ModelManager,
) -> Path | None:
    model_id = f"{ENGINE_MOONSHINE}:{runtime_config.moonshine_language}"
    return model_manager.installed_path(model_id)
