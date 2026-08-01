from __future__ import annotations

from pathlib import Path
from typing import Protocol

from app.catalog import ENGINE_WHISPER_CPP, ENGINE_WHISPERKIT
from app.config import Settings
from app.model_manager import ModelManager
from app.models.base import EngineHealth, TranscriptionEngine
from app.models.handy import HandyEngine
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
        if self.runtime_config.whisper_model == str(path):
            self.runtime_config.whisper_model = None
            changed = True
        if self.runtime_config.whisperkit_model == str(path):
            self.runtime_config.whisperkit_model = None
            changed = True
        if changed:
            self._apply()

    def set_engine(self, engine: str) -> None:
        if engine not in VALID_ENGINES:
            raise ValueError(f"Engine must be one of: {', '.join(VALID_ENGINES)}.")
        self.runtime_config.engine = engine
        if engine != ENGINE_WHISPER_CPP:
            self.runtime_config.whisper_model = None
        if engine != ENGINE_WHISPERKIT:
            self.runtime_config.whisperkit_model = None
        self._apply()

    def _apply(self) -> None:
        self.runtime_config.save(self.config_path)
        self._engine = self._build()

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
    installed = [
        model for model in model_manager.installed() if model.engine == ENGINE_WHISPER_CPP
    ]
    if installed:
        return max(installed, key=lambda model: model.size_bytes).path
    return settings.whisper_model


def _whisperkit_model_path(
    runtime_config: RuntimeConfig,
    model_manager: ModelManager,
) -> Path | None:
    if runtime_config.whisperkit_model:
        return Path(runtime_config.whisperkit_model)
    installed = [
        model for model in model_manager.installed() if model.engine == ENGINE_WHISPERKIT
    ]
    if installed:
        return max(installed, key=lambda model: model.size_bytes).path
    return None
