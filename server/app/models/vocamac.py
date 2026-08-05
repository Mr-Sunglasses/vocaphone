from __future__ import annotations

import plistlib
import shutil
from pathlib import Path

from app.errors import EngineUnavailableError, TranscriptionProcessError
from app.models.base import EngineHealth, EngineTranscription, TranscriptionOptions
from app.models.whisperkit import WhisperKitEngine

DEFAULT_VOCAMAC_APP = Path("/Applications/VocaMac.app")
DEFAULT_SUPPORT_DIR = Path("~/Library/Application Support/VocaMac")
DEFAULT_PREFERENCES_FILE = Path("~/Library/Preferences/com.vocamac.app.plist")
SELECTED_MODEL_KEY = "vocamac.selectedModelSize"
MODEL_REPOSITORY = "argmaxinc/whisperkit-coreml"

# VocaMac stores a `ModelSize` raw value in its preferences but names the model
# folder after the WhisperKit variant. This is `ModelManager.whisperKitModelName`
# from the VocaMac source.
MODEL_VARIANTS = {
    "tiny": "openai_whisper-tiny",
    "base": "openai_whisper-base",
    "small": "openai_whisper-small",
    "medium": "openai_whisper-medium",
    "large-v3": "openai_whisper-large-v3",
    "large-v3_turbo": "openai_whisper-large-v3_turbo",
    "large-v3-v20240930": "openai_whisper-large-v3-v20240930",
    "large-v3-v20240930_turbo": "openai_whisper-large-v3-v20240930_turbo",
    "large-v3-v20240930_626MB": "openai_whisper-large-v3-v20240930_626MB",
    "large-v3-v20240930_turbo_632MB": "openai_whisper-large-v3-v20240930_turbo_632MB",
    "distil-large-v3_594MB": "distil-whisper_distil-large-v3_594MB",
    "distil-large-v3_turbo_600MB": "distil-whisper_distil-large-v3_turbo_600MB",
}

REQUIRED_COMPONENTS = (
    "MelSpectrogram.mlmodelc",
    "AudioEncoder.mlmodelc",
    "TextDecoder.mlmodelc",
)
_MODEL_DEFINITIONS = ("model.mil", "model.mlmodel", "coremldata.bin")


class VocaMacEngine:
    """Adapter that runs VocaMac's downloaded Core ML models through WhisperKit.

    VocaMac has no headless transcription command, so unlike `HandyEngine` this
    adapter cannot delegate to the app itself. What it reuses is the app's model
    library: plain WhisperKit Core ML folders that `WhisperKitEngine` already
    knows how to serve, plus the tokenizers VocaMac downloaded alongside them.
    """

    def __init__(
        self,
        whisperkit_binary: str,
        model: str | None = None,
        *,
        app_path: Path | None = None,
        support_dir: Path | None = None,
        preferences_file: Path | None = None,
    ) -> None:
        self.whisperkit_binary = whisperkit_binary
        self.model = model
        self.app_path = app_path or DEFAULT_VOCAMAC_APP
        self.download_base = (support_dir or DEFAULT_SUPPORT_DIR.expanduser()) / "models"
        self.models_dir = self.download_base / "models" / MODEL_REPOSITORY
        self.preferences_file = preferences_file or DEFAULT_PREFERENCES_FILE.expanduser()
        self._delegate: WhisperKitEngine | None = None
        self._delegate_path: Path | None = None

    def is_available(self) -> bool:
        """Cheap synchronous check used while resolving the `auto` engine."""
        return (
            self.app_path.exists()
            and self._resolved_binary() is not None
            and bool(self._usable_models())
        )

    async def health(self) -> EngineHealth:
        models = self._usable_models()
        if not models:
            wanted = self._selected_variant()
            return EngineHealth(ready=False, name=f"vocamac:{wanted or 'no-model-selected'}")
        delegate = await self._delegate_for(models[0]).health()
        return EngineHealth(
            ready=self.app_path.exists() and delegate.ready,
            name=f"vocamac:{models[0].name}",
        )

    async def warmup(self) -> int:
        models = self._usable_models()
        if not models or not (await self.health()).ready:
            return 0
        return await self._delegate_for(models[0]).warmup()

    async def transcribe(
        self, audio_path: Path, options: TranscriptionOptions
    ) -> EngineTranscription:
        models = self._usable_models()
        if not models or not (await self.health()).ready:
            raise EngineUnavailableError(
                "VocaMac, one of its downloaded models, or the WhisperKit CLI is "
                "unavailable. Install VocaMac, download a model in its Models tab, "
                "and install the CLI with `brew install whisperkit-cli`."
            )
        last_error: TranscriptionProcessError | None = None
        for model_path in models:
            try:
                return await self._delegate_for(model_path).transcribe(audio_path, options)
            except TranscriptionProcessError as error:
                last_error = error
        if last_error is not None:
            raise last_error
        raise EngineUnavailableError("No usable VocaMac transcription model is available.")

    def close(self) -> None:
        delegate = self._delegate
        self._delegate = None
        self._delegate_path = None
        if delegate is not None:
            delegate.close()

    def _delegate_for(self, model_path: Path) -> WhisperKitEngine:
        """Keep one WhisperKit service alive until VocaMac's selection changes."""
        if self._delegate is not None and self._delegate_path == model_path:
            return self._delegate
        self.close()
        self._delegate = WhisperKitEngine(
            self.whisperkit_binary,
            model_path,
            tokenizer_path=self.download_base,
        )
        self._delegate_path = model_path
        return self._delegate

    def _usable_models(self) -> list[Path]:
        """VocaMac's selected model first, then its other complete downloads."""
        selected = self._selected_variant()
        preferred = self.models_dir / selected if selected else None
        if preferred is not None and not _model_is_usable(preferred):
            preferred = None
        if self.model:
            # A configured model is a choice, not a hint: never substitute silently.
            return [preferred] if preferred is not None else []
        models = [
            directory
            for directory in self._downloaded_directories()
            if directory != preferred and _model_is_usable(directory)
        ]
        models.sort(key=_model_weight_bytes, reverse=True)
        if preferred is not None:
            models.insert(0, preferred)
        return models

    def _selected_variant(self) -> str | None:
        if self.model:
            return MODEL_VARIANTS.get(self.model, self.model)
        try:
            with self.preferences_file.open("rb") as handle:
                payload = plistlib.load(handle)
            selected = payload[SELECTED_MODEL_KEY]
        except (OSError, plistlib.InvalidFileException, KeyError, TypeError):
            return None
        return MODEL_VARIANTS.get(selected) if isinstance(selected, str) else None

    def _downloaded_directories(self) -> list[Path]:
        try:
            return sorted(entry for entry in self.models_dir.iterdir() if entry.is_dir())
        except OSError:
            return []

    def _resolved_binary(self) -> str | None:
        candidate = Path(self.whisperkit_binary).expanduser()
        if candidate.is_file():
            return str(candidate)
        return shutil.which(self.whisperkit_binary)


def _model_is_usable(directory: Path) -> bool:
    """Reject partial downloads the way VocaMac's own asset check does.

    An interrupted download leaves the variant folder in place with some Core ML
    components empty, and Core ML then refuses to load the model at transcription
    time rather than at selection time.
    """
    return all(_component_is_usable(directory / name) for name in REQUIRED_COMPONENTS)


def _component_is_usable(component: Path) -> bool:
    return (
        (component / "metadata.json").is_file()
        and any((component / name).is_file() for name in _MODEL_DEFINITIONS)
        and (component / "weights" / "weight.bin").is_file()
    )


def _model_weight_bytes(directory: Path) -> int:
    """Rank complete models by weight size rather than walking gigabytes of files."""
    total = 0
    for name in REQUIRED_COMPONENTS:
        try:
            total += (directory / name / "weights" / "weight.bin").stat().st_size
        except OSError:
            return 0
    return total
