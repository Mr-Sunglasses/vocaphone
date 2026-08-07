from __future__ import annotations

from html import escape

from app.schemas import EngineStatus
from app.system import engine_requirement

ENGINE_LABELS = {
    "auto": "Auto (recommended)",
    "vocamac": "VocaMac app",
    "handy": "Handy app",
    "whisper.cpp": "whisper.cpp",
    "whisperkit": "WhisperKit",
    "faster-whisper": "faster-whisper",
    "moonshine": "Moonshine",
    "sherpa-onnx": "sherpa-onnx",
    "mlx-audio": "MLX Audio",
}

ENGINE_HINTS = {
    "auto": "Uses the fastest compatible installed local engine for this machine.",
    "vocamac": (
        "Optional Apple silicon Mac app. Reuses VocaMac's downloaded Core ML "
        "models through whisperkit-cli. No download needed."
    ),
    "handy": (
        "Optional macOS app. Reuses the Handy app and its downloaded models. No download needed."
    ),
    "whisper.cpp": "Runs local GGML models with the whisper-cli binary.",
    "whisperkit": "Runs Core ML models with whisperkit-cli on Apple Silicon Macs.",
    "faster-whisper": "Keeps a CTranslate2 model loaded; CPU INT8 is the Linux default.",
    "moonshine": "Fast, language-specific local models; compatible English tiers stream live.",
    "sherpa-onnx": "Compact INT8 CPU models for fast macOS and Linux transcription.",
    "mlx-audio": "Runs Apple-silicon-native MLX models with persistent loading.",
}


def _engine_option_label(engine: str) -> str:
    """Name the host an engine needs, so the picker explains its own contents."""
    label = ENGINE_LABELS.get(engine, engine)
    requirement = engine_requirement(engine)
    return f"{label} ({requirement} only)" if requirement else label


def engine_pill_fragment(engine: EngineStatus) -> str:
    css = "ready" if engine.ready else "not-ready"
    label = escape(engine.name or engine.id)
    return (
        f'<div id="engine-pill" class="pill {css}" '
        f'hx-get="/ui/partials/engine-pill" hx-trigger="every 5s" hx-swap="outerHTML">'
        f"{label}</div>"
    )


def engine_pill_oob(engine: EngineStatus) -> str:
    css = "ready" if engine.ready else "not-ready"
    label = escape(engine.name or engine.id)
    return (
        f'<div id="engine-pill" class="pill {css}" hx-swap-oob="true"'
        f' hx-get="/ui/partials/engine-pill" hx-trigger="every 5s" hx-swap="outerHTML">'
        f"{label}</div>"
    )


def engine_update_fragment(engine: EngineStatus, message: str) -> str:
    css = "ok" if engine.ready else "missing"
    return (
        f'<span class="badge {css}">{escape(engine.name or engine.id)}'
        f"{' ready' if engine.ready else ' not ready'}</span> "
        f"{escape(message)}{engine_pill_oob(engine)}"
    )
