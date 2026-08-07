from __future__ import annotations

import asyncio
import json
import secrets
import shutil
import socket
import subprocess
import time
import urllib.error
import urllib.request
from contextlib import suppress
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from app.errors import EngineUnavailableError, TranscriptionProcessError
from app.models.base import EngineHealth, EngineTranscription, TranscriptionOptions


@dataclass(slots=True)
class _WhisperKitServer:
    process: subprocess.Popen[bytes]
    port: int


class _PersistentServerUnavailable(Exception):
    """The installed CLI cannot start or reach its persistent local server."""


class WhisperKitEngine:
    """Persistent Apple-silicon WhisperKit adapter with a legacy CLI fallback."""

    def __init__(
        self,
        binary: str,
        model_path: Path | None,
        *,
        tokenizer_path: Path | None = None,
    ) -> None:
        self.binary = binary
        self.model_path = model_path
        # Set when another app already downloaded the matching tokenizer files,
        # so the CLI reuses them instead of fetching them from Hugging Face.
        self.tokenizer_path = tokenizer_path
        self._server: _WhisperKitServer | None = None
        self._load_lock = asyncio.Lock()
        self._inference_lock = asyncio.Lock()

    async def health(self) -> EngineHealth:
        resolved = self._resolved_binary()
        model_ready = self.model_path is not None and (self.model_path / "config.json").is_file()
        model_name = self.model_path.name if self.model_path else "no-model-selected"
        return EngineHealth(
            ready=resolved is not None and model_ready,
            name=f"whisperkit:{model_name}",
        )

    async def warmup(self) -> int:
        if not (await self.health()).ready or self.model_path is None:
            return 0
        try:
            await self._ensure_server()
        except _PersistentServerUnavailable:
            # Older WhisperKit CLIs remain usable through the one-shot fallback.
            return 0
        return _directory_size(self.model_path)

    async def transcribe(
        self, audio_path: Path, options: TranscriptionOptions
    ) -> EngineTranscription:
        resolved = self._resolved_binary()
        health = await self.health()
        if resolved is None or not health.ready or self.model_path is None:
            raise EngineUnavailableError(
                "The WhisperKit CLI or the selected model is unavailable. "
                "Install it with `brew install whisperkit-cli` and download a model."
            )

        async with self._inference_lock:
            load_started = time.monotonic()
            try:
                server, loaded_now = await self._ensure_server()
            except _PersistentServerUnavailable:
                return await self._transcribe_with_cli(resolved, audio_path, options)
            model_load_ms = _elapsed_ms(load_started) if loaded_now else 0

            for attempt in range(2):
                inference_started = time.monotonic()
                try:
                    transcript = await asyncio.wait_for(
                        asyncio.to_thread(
                            _server_transcription,
                            server,
                            self.model_path,
                            audio_path,
                            options.language,
                        ),
                        timeout=180,
                    )
                except TimeoutError as error:
                    raise TranscriptionProcessError(
                        "WhisperKit transcription timed out."
                    ) from error
                except _PersistentServerUnavailable:
                    await asyncio.to_thread(self._discard_server, server)
                    if attempt == 0:
                        try:
                            reload_started = time.monotonic()
                            server, reloaded = await self._ensure_server()
                            if reloaded:
                                model_load_ms += _elapsed_ms(reload_started)
                            continue
                        except _PersistentServerUnavailable:
                            pass
                    return await self._transcribe_with_cli(resolved, audio_path, options)
                if not transcript:
                    raise TranscriptionProcessError("WhisperKit returned an empty transcript.")
                return EngineTranscription(
                    text=transcript,
                    model_load_ms=model_load_ms,
                    inference_ms=_elapsed_ms(inference_started),
                )

        raise TranscriptionProcessError("WhisperKit transcription failed.")

    async def _ensure_server(self) -> tuple[_WhisperKitServer, bool]:
        if self._server is not None and self._server.process.poll() is None:
            return self._server, False
        async with self._load_lock:
            if self._server is not None and self._server.process.poll() is None:
                return self._server, False
            self.close()
            resolved = self._resolved_binary()
            if resolved is None or self.model_path is None:
                raise _PersistentServerUnavailable("WhisperKit is unavailable.")
            self._server = await asyncio.to_thread(
                _start_server,
                resolved,
                self.model_path,
                self.tokenizer_path,
            )
            return self._server, True

    async def _transcribe_with_cli(
        self,
        resolved: str,
        audio_path: Path,
        options: TranscriptionOptions,
    ) -> EngineTranscription:
        inference_started = time.monotonic()
        arguments = [
            resolved,
            "transcribe",
            "--audio-path",
            str(audio_path),
            "--model-path",
            str(self.model_path),
        ]
        if self.tokenizer_path is not None:
            arguments.extend(["--download-tokenizer-path", str(self.tokenizer_path)])
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
        return EngineTranscription(
            text=transcript,
            inference_ms=_elapsed_ms(inference_started),
        )

    def close(self) -> None:
        server = self._server
        self._server = None
        if server is None or server.process.poll() is not None:
            return
        server.process.terminate()
        try:
            server.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            server.process.kill()
            server.process.wait(timeout=3)

    def _discard_server(self, server: _WhisperKitServer) -> None:
        if self._server is server:
            self.close()

    def _resolved_binary(self) -> str | None:
        candidate = Path(self.binary).expanduser()
        if candidate.is_file():
            return str(candidate)
        return shutil.which(self.binary)

    def __del__(self) -> None:
        with suppress(Exception):
            self.close()


def _start_server(
    binary: str,
    model_path: Path,
    tokenizer_path: Path | None = None,
) -> _WhisperKitServer:
    port = _available_loopback_port()
    arguments = [
        binary,
        "serve",
        "--model-path",
        str(model_path),
        "--host",
        "127.0.0.1",
        "--port",
        str(port),
    ]
    if tokenizer_path is not None:
        arguments.extend(["--download-tokenizer-path", str(tokenizer_path)])
    process = subprocess.Popen(
        arguments,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    server = _WhisperKitServer(process=process, port=port)
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise _PersistentServerUnavailable(
                "The installed WhisperKit CLI does not support persistent serving."
            )
        try:
            with urllib.request.urlopen(_health_url(server), timeout=1) as response:
                if response.status == 200:
                    return server
        except (OSError, urllib.error.URLError):
            time.sleep(0.1)
    process.terminate()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
    raise _PersistentServerUnavailable("WhisperKit's local server did not become ready.")


def _server_transcription(
    server: _WhisperKitServer,
    model_path: Path,
    audio_path: Path,
    language: str,
) -> str:
    if server.process.poll() is not None:
        raise _PersistentServerUnavailable("WhisperKit's local server stopped.")
    boundary = f"vocaphone-{secrets.token_hex(12)}"
    fields = [("model", model_path.name)]
    if language != "auto":
        fields.append(("language", language))
    body = _multipart_body(boundary, fields, audio_path)
    request = urllib.request.Request(
        f"http://127.0.0.1:{server.port}/v1/audio/transcriptions",
        data=body,
        method="POST",
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    try:
        with urllib.request.urlopen(request, timeout=180) as response:
            payload: dict[str, Any] = json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")[-240:]
        raise TranscriptionProcessError(
            f"WhisperKit server rejected the audio: {detail or error.reason}"
        ) from error
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise TranscriptionProcessError("WhisperKit returned invalid JSON.") from error
    except (OSError, urllib.error.URLError) as error:
        raise _PersistentServerUnavailable("WhisperKit's local server is unreachable.") from error
    transcript = payload.get("text") if isinstance(payload, dict) else None
    if not isinstance(transcript, str):
        raise TranscriptionProcessError("WhisperKit returned an invalid server response.")
    return transcript.strip()


def _multipart_body(
    boundary: str,
    fields: list[tuple[str, str]],
    audio_path: Path,
) -> bytes:
    chunks: list[bytes] = []
    for name, value in fields:
        chunks.append(
            (
                f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'
            ).encode()
        )
    safe_name = audio_path.name.replace('"', "")
    chunks.append(
        (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="file"; filename="{safe_name}"\r\n'
            "Content-Type: audio/wav\r\n\r\n"
        ).encode()
    )
    chunks.append(audio_path.read_bytes())
    chunks.append(f"\r\n--{boundary}--\r\n".encode())
    return b"".join(chunks)


def _health_url(server: _WhisperKitServer) -> str:
    return f"http://127.0.0.1:{server.port}/health"


def _available_loopback_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def _extract_transcript(output: str) -> str:
    """The legacy CLI prints the transcript on stdout, possibly with log lines."""
    lines = [line.strip() for line in output.strip().splitlines()]
    text_lines = [line for line in lines if line and not line.startswith("[")]
    return " ".join(text_lines).strip()


def _directory_size(path: Path) -> int:
    return sum(file.stat().st_size for file in path.rglob("*") if file.is_file())


def _elapsed_ms(started: float) -> int:
    return max(0, int((time.monotonic() - started) * 1000))
