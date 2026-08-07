from __future__ import annotations

import asyncio
import json
import sys
import threading
from array import array
from contextlib import suppress
from typing import Any

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from app.context import GatewayContext
from app.models.base import StreamingEngine
from app.scripts import transcript_matches_language
from app.serializers import joined_stream_lines
from app.text_styles import apply_writing_style

router = APIRouter()


@router.websocket("/v1/stream")
async def stream_transcription(websocket: WebSocket) -> None:
    """Experimental float32 PCM stream for a streaming-capable engine.

    Any engine exposing `supports_streaming` (True), `streaming_lock`, and
    `create_stream()` returning an object with `add_listener`/`add_audio`/
    `stop` works here — currently Moonshine and the sherpa-onnx streaming
    zipformer model.
    """
    ctx: GatewayContext = websocket.app.state.ctx
    if not ctx.token_is_valid(websocket.headers.get("authorization")):
        await websocket.close(code=4401, reason="Unauthorized")
        return
    selected_engine = ctx.engine_provider.current()
    if not isinstance(selected_engine, StreamingEngine) or not selected_engine.supports_streaming:
        selected_health = await selected_engine.health()
        await websocket.accept()
        await websocket.send_json(
            {
                "type": "unsupported",
                "reason": "active_engine",
                "engine": selected_health.name,
            }
        )
        await websocket.close(code=4409, reason="Active engine does not support streaming")
        return
    selected_health = await selected_engine.health()
    if not selected_health.ready:
        await websocket.accept()
        await websocket.send_json(
            {
                "type": "unavailable",
                "reason": "engine_not_ready",
                "engine": selected_health.name,
            }
        )
        await websocket.close(code=4410, reason="Streaming engine is not ready")
        return
    await websocket.accept()
    stream: Any | None = None
    lines: dict[int, str] = {}
    lines_lock = threading.Lock()
    sample_rate = 0
    style = "casual"
    language = "auto"
    received_samples = 0
    try:
        start = await websocket.receive_json()
        if start.get("type") != "start":
            raise ValueError("The first stream message must be start.")
        sample_rate = int(start.get("sample_rate", 0))
        if not 8_000 <= sample_rate <= 96_000:
            raise ValueError("Sample rate must be between 8000 and 96000 Hz.")
        language = str(start.get("language", "auto"))
        style = str(start.get("style", "casual"))
        if style not in {"raw", "clean", "formal", "casual", "very_casual", "excited"}:
            raise ValueError("Unsupported writing style.")
        async with selected_engine.streaming_lock:
            stream = await selected_engine.create_stream()

            def receive_event(event: object) -> None:
                line = getattr(event, "line", None)
                text_value = getattr(line, "text", "") if line is not None else ""
                line_id = getattr(line, "line_id", None) if line is not None else None
                if isinstance(line_id, int) and text_value:
                    with lines_lock:
                        lines[line_id] = str(text_value).strip()

            await asyncio.to_thread(stream.add_listener, receive_event)
            await websocket.send_json(
                {"type": "ready", "engine": selected_health.name.split(":", 1)[0]}
            )
            while True:
                message = await websocket.receive()
                if message.get("type") == "websocket.disconnect":
                    break
                chunk = message.get("bytes")
                if chunk is not None:
                    if len(chunk) % 4:
                        raise ValueError("PCM chunks must contain float32 samples.")
                    samples = array("f")
                    samples.frombytes(chunk)
                    if sys.byteorder != "little":
                        samples.byteswap()
                    received_samples += len(samples)
                    if received_samples > sample_rate * ctx.settings.maximum_duration_seconds:
                        raise ValueError("The stream exceeds the recording duration limit.")
                    await asyncio.to_thread(stream.add_audio, samples.tolist(), sample_rate)
                    with lines_lock:
                        partial = joined_stream_lines(lines)
                    if partial:
                        await websocket.send_json({"type": "partial", "transcript": partial})
                    continue
                text_message = message.get("text")
                if text_message:
                    command = json.loads(text_message)
                    if command.get("type") == "finish":
                        final_result = await asyncio.to_thread(stream.stop)
                        with lines_lock:
                            for line in getattr(final_result, "lines", []) or []:
                                if getattr(line, "text", ""):
                                    lines[int(line.line_id)] = str(line.text).strip()
                            joined = joined_stream_lines(lines)
                            if not transcript_matches_language(joined, language):
                                raise ValueError(
                                    "The model transcribed this as a different "
                                    f"language than {language}."
                                )
                            transcript = apply_writing_style(joined, style, language)
                        if not transcript:
                            raise ValueError("Moonshine returned an empty transcript.")
                        await asyncio.to_thread(stream.close)
                        stream = None
                        await websocket.send_json({"type": "complete", "transcript": transcript})
                        await websocket.close(code=1000)
                        return
    except WebSocketDisconnect:
        pass
    except Exception as error:  # noqa: BLE001 - sanitized protocol error
        with suppress(RuntimeError):
            await websocket.send_json(
                {"type": "error", "message": str(error)[-200:] or "Streaming failed."}
            )
            await websocket.close(code=1011)
    finally:
        if stream is not None:
            with suppress(Exception):
                await asyncio.to_thread(stream.close)
