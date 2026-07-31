from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
from typing import Any

from app.errors import EngineUnavailableError, TranscriptionProcessError
from app.models.base import EngineHealth, TranscriptionOptions


class HandyEngine:
    """Adapter for Handy's headless file-transcription interface."""

    def __init__(
        self,
        binary: Path,
        model: str | None = None,
        *,
        fallback_model: str | None = None,
        settings_file: Path | None = None,
        huggingface_cache: Path | None = None,
    ) -> None:
        self.binary = binary
        self.settings_file = (
            settings_file
            or Path("~/Library/Application Support/com.pais.handy/settings_store.json").expanduser()
        )
        self.huggingface_cache = huggingface_cache or Path("~/.cache/huggingface/hub").expanduser()
        self.model = model or self._read_selected_model()
        self.fallback_model = fallback_model

    async def health(self) -> EngineHealth:
        available_models = self._downloaded_models()
        selected_model = (
            available_models[0] if available_models else self.model or "no-model-selected"
        )
        ready = self.binary.is_file() and os.access(self.binary, os.X_OK) and bool(available_models)
        return EngineHealth(
            ready=ready,
            name=f"handy:{selected_model}",
        )

    async def transcribe(self, audio_path: Path, options: TranscriptionOptions) -> str:
        health = await self.health()
        if not health.ready:
            raise EngineUnavailableError(
                "Handy, its selected model, or the downloaded model file is unavailable."
            )
        last_error: TranscriptionProcessError | None = None
        for model in self._downloaded_models():
            try:
                return await self._transcribe_with_model(audio_path, model)
            except TranscriptionProcessError as error:
                last_error = error
        if last_error is not None:
            raise last_error
        raise EngineUnavailableError("No downloaded Handy transcription model is available.")

    async def _transcribe_with_model(self, audio_path: Path, model: str) -> str:
        arguments = [
            str(self.binary),
            "--transcribe-file",
            str(audio_path),
            "--json",
        ]
        arguments.extend(["--model", model])
        process = await asyncio.create_subprocess_exec(
            *arguments,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout, stderr = await asyncio.wait_for(process.communicate(), timeout=75)
        except TimeoutError as error:
            process.kill()
            await process.wait()
            raise TranscriptionProcessError("Handy transcription timed out.") from error
        if process.returncode != 0:
            message = stderr.decode("utf-8", errors="replace").strip().splitlines()
            detail = message[-1][:200] if message else "unknown Handy error"
            raise TranscriptionProcessError(f"Handy exited unsuccessfully: {detail}")
        try:
            payload: dict[str, Any] = json.loads(stdout)
            transcript = payload["text"]
        except (json.JSONDecodeError, KeyError, TypeError) as error:
            raise TranscriptionProcessError(
                "Handy returned an invalid transcription response."
            ) from error
        if not isinstance(transcript, str) or not transcript.strip():
            raise TranscriptionProcessError("Handy returned an empty transcript.")
        return transcript.strip()

    def _downloaded_models(self) -> list[str]:
        models: list[str] = []
        for model in (self.model, self.fallback_model):
            if model and model not in models and self._model_is_downloaded(model):
                models.append(model)
        return models

    def _read_selected_model(self) -> str | None:
        try:
            payload = json.loads(self.settings_file.read_text(encoding="utf-8"))
            selected = payload["settings"]["selected_model"]
        except (OSError, json.JSONDecodeError, KeyError, TypeError):
            return None
        return selected if isinstance(selected, str) and selected else None

    def _model_is_downloaded(self, model: str) -> bool:
        components = model.split("/")
        if len(components) < 3:
            return False
        repository = "/".join(components[:-1])
        filename = components[-1]
        cache_name = "models--" + repository.replace("/", "--")
        snapshots = self.huggingface_cache / cache_name / "snapshots"
        return any(candidate.is_file() for candidate in snapshots.glob(f"*/{filename}"))
