from __future__ import annotations

import asyncio
import tempfile
from pathlib import Path

from app.errors import EngineUnavailableError, TranscriptionProcessError
from app.models.base import EngineHealth, TranscriptionOptions
from app.models.warmup import prefetch_model_paths


class WhisperCppEngine:
    def __init__(self, binary: Path, model: Path) -> None:
        self.binary = binary
        self.model = model

    async def health(self) -> EngineHealth:
        ready = self.binary.is_file() and self.model.is_file()
        return EngineHealth(ready=ready, name=f"whisper.cpp:{self.model.name}")

    async def warmup(self) -> int:
        if not (await self.health()).ready:
            return 0
        return await asyncio.to_thread(prefetch_model_paths, [self.model])

    async def transcribe(self, audio_path: Path, options: TranscriptionOptions) -> str:
        health = await self.health()
        if not health.ready:
            raise EngineUnavailableError("The whisper.cpp binary or selected model is unavailable.")
        with tempfile.TemporaryDirectory(prefix="localflow-transcript-") as temporary:
            output_stem = Path(temporary) / "result"
            arguments = [
                str(self.binary),
                "-m",
                str(self.model),
                "-f",
                str(audio_path),
                "-otxt",
                "-of",
                str(output_stem),
                "-np",
                "-nt",
            ]
            if options.language != "auto":
                arguments.extend(["-l", options.language])
            process = await asyncio.create_subprocess_exec(
                *arguments,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.PIPE,
            )
            try:
                _, stderr = await asyncio.wait_for(process.communicate(), timeout=75)
            except TimeoutError as error:
                process.kill()
                await process.wait()
                raise TranscriptionProcessError("Transcription timed out.") from error
            if process.returncode != 0:
                message = (stderr or b"").decode("utf-8", errors="replace").strip()
                raise TranscriptionProcessError(
                    f"whisper.cpp exited unsuccessfully: {message[-200:]}"
                )
            output = output_stem.with_suffix(".txt")
            if not output.is_file():
                raise TranscriptionProcessError("whisper.cpp did not produce a transcript.")
            transcript = output.read_text(encoding="utf-8").strip()
            if not transcript:
                raise TranscriptionProcessError("The transcription result was empty.")
            return transcript
