from __future__ import annotations

import asyncio
import shutil
from pathlib import Path

from app.errors import EngineUnavailableError, TranscriptionProcessError
from app.models.base import EngineHealth, TranscriptionOptions
from app.models.warmup import prefetch_model_paths


class WhisperKitEngine:
    """Adapter for the WhisperKit command line tool (`brew install whisperkit-cli`)."""

    def __init__(self, binary: str, model_path: Path | None) -> None:
        self.binary = binary
        self.model_path = model_path

    async def health(self) -> EngineHealth:
        resolved = self._resolved_binary()
        model_ready = self.model_path is not None and (self.model_path / "config.json").is_file()
        model_name = self.model_path.name if self.model_path else "no-model-selected"
        return EngineHealth(
            ready=resolved is not None and model_ready,
            name=f"whisperkit:{model_name}",
        )

    async def warmup(self) -> int:
        if self.model_path is None or not (await self.health()).ready:
            return 0
        return await asyncio.to_thread(prefetch_model_paths, [self.model_path])

    async def transcribe(self, audio_path: Path, options: TranscriptionOptions) -> str:
        resolved = self._resolved_binary()
        health = await self.health()
        if resolved is None or not health.ready or self.model_path is None:
            raise EngineUnavailableError(
                "The WhisperKit CLI or the selected model is unavailable. "
                "Install it with `brew install whisperkit-cli` and download a model."
            )
        arguments = [
            resolved,
            "transcribe",
            "--audio-path",
            str(audio_path),
            "--model-path",
            str(self.model_path),
        ]
        if options.language != "auto":
            arguments.extend(["--language", options.language])
        process = await asyncio.create_subprocess_exec(
            *arguments,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout, stderr = await asyncio.wait_for(process.communicate(), timeout=180)
        except TimeoutError as error:
            process.kill()
            await process.wait()
            raise TranscriptionProcessError("WhisperKit transcription timed out.") from error
        if process.returncode != 0:
            message = stderr.decode("utf-8", errors="replace").strip().splitlines()
            detail = message[-1][:200] if message else "unknown WhisperKit error"
            raise TranscriptionProcessError(f"WhisperKit exited unsuccessfully: {detail}")
        transcript = _extract_transcript(stdout.decode("utf-8", errors="replace"))
        if not transcript:
            raise TranscriptionProcessError("WhisperKit returned an empty transcript.")
        return transcript

    def _resolved_binary(self) -> str | None:
        candidate = Path(self.binary).expanduser()
        if candidate.is_file():
            return str(candidate)
        return shutil.which(self.binary)


def _extract_transcript(output: str) -> str:
    """The CLI prints the transcript on stdout, possibly alongside log lines."""
    lines = [line.strip() for line in output.strip().splitlines()]
    text_lines = [line for line in lines if line and not line.startswith("[")]
    return " ".join(text_lines).strip()
