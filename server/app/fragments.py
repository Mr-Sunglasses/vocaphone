from __future__ import annotations

from html import escape
from urllib.parse import quote

from app.schemas import (
    AdminModelEntry,
    AdminStatusResponse,
    ConfigResponse,
    EngineStatus,
)

ENGINE_LABELS = {
    "auto": "Auto (recommended)",
    "handy": "Handy app",
    "whisper.cpp": "whisper.cpp",
    "whisperkit": "WhisperKit",
}

ENGINE_HINTS = {
    "auto": "Uses Handy when installed, then downloaded WhisperKit or whisper.cpp models.",
    "handy": "Reuses the Handy app and its downloaded models. No download needed.",
    "whisper.cpp": "Runs ggml models with the whisper-cli binary (brew install whisper-cpp).",
    "whisperkit": "Runs CoreML models with whisperkit-cli (brew install whisperkit-cli).",
}


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


def overview_fragment(status: AdminStatusResponse) -> str:
    checks = [
        ("Gateway token configured", status.setup.token_configured, ""),
        ("FFmpeg installed", status.setup.ffmpeg_available, "brew install ffmpeg"),
        (
            "Speech engine CLI installed",
            status.setup.engine_binary_available,
            "brew install whisperkit-cli",
        ),
        ("Speech model downloaded", status.setup.model_installed, "Open the Models tab"),
        ("Engine ready to transcribe", status.setup.engine_ready, "Select a downloaded model"),
    ]
    checklist = "".join(
        "<li>"
        f'<span class="check {"ok" if ok else "missing"}">{"✓" if ok else "✗"}</span>'
        f"<span>{escape(label)}</span>"
        + ("" if ok or not hint else f'<code class="hint">{escape(hint)}</code>')
        + "</li>"
        for label, ok, hint in checks
    )
    facts = _facts(
        [
            ("Chip", status.system.chip),
            ("Memory", f"{status.system.ram_gb:g} GB"),
            ("OS", f"{status.system.os} ({status.system.arch})"),
            ("Gateway", f"http://{status.bind_host}:{status.port} · v{status.version}"),
        ]
    )
    rows = "".join(
        "<tr>"
        f"<td>{escape(dependency.name)}</td>"
        f'<td><span class="badge {"ok" if dependency.available else "missing"}">'
        f'{"installed" if dependency.available else "missing"}</span></td>'
        f"<td><code>{escape(dependency.path or dependency.install_hint or '—')}</code></td>"
        "</tr>"
        for dependency in status.dependencies
    )
    return f"""
      <div class="grid two">
        <div class="card">
          <h2>Setup checklist</h2>
          <ul class="checklist">{checklist}</ul>
        </div>
        <div class="card">
          <h2>This Mac</h2>
          <dl class="facts">{facts}</dl>
        </div>
      </div>
      <div class="card">
        <h2>Dependencies</h2>
        <table class="table">
          <thead><tr><th>Tool</th><th>Status</th><th>Path / install</th></tr></thead>
          <tbody>{rows}</tbody>
        </table>
      </div>
      <div class="card">
        <h2>Next steps</h2>
        <ol class="steps">
          <li>Install a speech engine: <code>brew install whisperkit-cli</code>
            (recommended on Apple&nbsp;silicon) or <code>brew install whisper-cpp</code>.</li>
          <li>Open the <strong>Models</strong> tab and download a recommended model.</li>
          <li>Press <strong>Select</strong> on the model to make it active.</li>
          <li>Verify everything in the <strong>Test</strong> tab with your microphone.</li>
          <li>Expose the gateway privately with <code>tailscale serve</code> and pair the
            iPhone app.</li>
        </ol>
      </div>
    """


def models_fragment(entries: list[AdminModelEntry]) -> str:
    return f"""
      <div class="card">
        <div class="card-header">
          <h2>Model library</h2>
        </div>
        <p class="muted">Models are downloaded from Hugging Face and stay on this Mac.
          Recommended picks match your hardware.</p>
        <div id="models-list"
             hx-get="/ui/partials/models-list"
             hx-trigger="every 1500ms"
             hx-swap="innerHTML">
          {models_list_fragment(entries)}
        </div>
      </div>
      <div class="card">
        <h2>Custom whisper.cpp model</h2>
        <p class="muted">Paste a direct HTTPS link to a <code>.bin</code> / <code>.gguf</code>
          file, e.g. from your own Hugging Face repo.</p>
        <form hx-post="/ui/partials/models/custom" hx-target="#models-list" hx-swap="innerHTML">
          <div class="row">
            <input name="url" type="url" required
                   placeholder="https://huggingface.co/&hellip;/resolve/main/model.gguf" />
            <button type="submit" class="primary">Download</button>
          </div>
        </form>
      </div>
    """


def models_list_fragment(entries: list[AdminModelEntry]) -> str:
    groups: dict[str, list[AdminModelEntry]] = {}
    for entry in entries:
        groups.setdefault(entry.engine, []).append(entry)
    parts: list[str] = []
    for engine, items in groups.items():
        title = "Custom models" if engine == "custom" else escape(ENGINE_LABELS.get(engine, engine))
        rows = "".join(_model_row(item) for item in items)
        parts.append(
            f"<h3 class='group-title'>{title}</h3>"
            f'<table class="table models"><tbody>{rows}</tbody></table>'
        )
    return "".join(parts)


def _model_row(entry: AdminModelEntry) -> str:
    encoded_id = quote(entry.id, safe="")
    badges = ""
    if entry.recommended:
        badges += '<span class="badge recommended">recommended</span>'
    if entry.active:
        badges += '<span class="badge active">active</span>'

    if entry.state == "downloading":
        percent = round((entry.progress or 0) * 100)
        downloaded = _format_bytes(entry.downloaded_bytes or 0)
        total = _format_bytes(entry.total_bytes or 0)
        action = (
            f'<div class="progress"><div class="bar" style="width:{percent}%"></div></div>'
            f'<span class="muted small">{percent}% · {downloaded} / {total}</span>'
            f'<button class="ghost small" hx-post="/ui/partials/models/{encoded_id}/cancel"'
            f' hx-target="#models-list" hx-swap="innerHTML">Cancel</button>'
        )
    elif entry.state == "installed":
        select_button = (
            ""
            if entry.active
            else (
                f'<button class="primary small"'
                f' hx-post="/ui/partials/models/{encoded_id}/select"'
                f' hx-target="#models-list" hx-swap="innerHTML">Select</button>'
            )
        )
        action = (
            f"{select_button}"
            f'<button class="ghost small danger"'
            f' hx-delete="/ui/partials/models/{encoded_id}"'
            f' hx-confirm="Delete {escape(entry.label)} from this Mac?"'
            f' hx-target="#models-list" hx-swap="innerHTML">Delete</button>'
        )
    else:
        note = (
            f'<p class="error small">Download failed: {escape(entry.error)}</p>'
            if entry.error
            else ""
        )
        action = (
            f"{note}"
            f'<button class="primary small"'
            f' hx-post="/ui/partials/models/{encoded_id}/download"'
            f' hx-target="#models-list" hx-swap="innerHTML">Download</button>'
        )

    return (
        "<tr>"
        f"<td class='model-name'>{escape(entry.label)} {badges}"
        f"<span class='muted small'>{escape(entry.languages)} · {escape(entry.quality)}</span></td>"
        f"<td class='size'>{_format_bytes(entry.size_bytes)}</td>"
        f"<td class='actions'>{action}</td>"
        "</tr>"
    )


def settings_fragment(config: ConfigResponse, paths: list[tuple[str, str]]) -> str:
    options = "".join(
        f'<option value="{escape(value)}"{" selected" if value == config.engine else ""}>'
        f"{escape(ENGINE_LABELS.get(value, value))}</option>"
        for value in config.available_engines
    )
    hint = escape(ENGINE_HINTS.get(config.engine, ""))
    facts = _facts(paths)
    return f"""
      <div class="card">
        <h2>Speech engine</h2>
        <p class="muted">Choose which local engine transcribes incoming audio.
          Selecting a model in the Models tab sets this automatically.</p>
        <form hx-put="/ui/partials/config" hx-target="#engine-result" hx-swap="innerHTML">
          <div class="row">
            <select name="engine">{options}</select>
            <button type="submit" class="primary">Apply</button>
          </div>
        </form>
        <p id="engine-result" class="muted">{hint}</p>
      </div>
      <div class="card">
        <h2>Paths</h2>
        <dl class="facts">{facts}</dl>
      </div>
      <div class="card danger-zone">
        <h2>Connection</h2>
        <p class="muted">The WebUI stores the bearer token only in this browser.</p>
        <button id="forget-token" class="ghost">Forget token on this browser</button>
      </div>
    """


def engine_update_fragment(engine: EngineStatus, message: str) -> str:
    css = "ok" if engine.ready else "missing"
    return (
        f'<span class="badge {css}">{escape(engine.name or engine.id)}'
        f'{" ready" if engine.ready else " not ready"}</span> '
        f"{escape(message)}{engine_pill_oob(engine)}"
    )


def test_fragment() -> str:
    return """
      <div class="card">
        <h2>Try your pipeline</h2>
        <p class="muted">Record a short clip with this Mac's microphone. The audio is
          normalized with FFmpeg and transcribed by the active engine &mdash; exactly like
          an iPhone dictation.</p>
        <div class="row">
          <select id="test-language">
            <option value="auto">Detect language</option>
            <option value="en">English</option>
            <option value="de">German</option>
            <option value="es">Spanish</option>
            <option value="fr">French</option>
            <option value="it">Italian</option>
            <option value="pt">Portuguese</option>
            <option value="nl">Dutch</option>
            <option value="ja">Japanese</option>
            <option value="zh">Chinese</option>
          </select>
          <button id="record-toggle" class="primary">Start recording</button>
        </div>
        <p id="record-status" class="muted"></p>
        <div id="test-result" class="result hidden">
          <h3>Transcript</h3>
          <p id="test-transcript"></p>
          <p id="test-meta" class="muted"></p>
        </div>
        <p id="test-error" class="error hidden"></p>
      </div>
    """


def error_fragment(message: str) -> str:
    return f'<p class="error">{escape(message)}</p>'


def _facts(items: list[tuple[str, str]]) -> str:
    return "".join(
        f"<dt>{escape(label)}</dt><dd>{escape(value)}</dd>" for label, value in items
    )


def _format_bytes(size: int) -> str:
    if size >= 1_000_000_000:
        return f"{size / 1_000_000_000:.1f} GB"
    if size >= 1_000_000:
        return f"{size / 1_000_000:.0f} MB"
    if size >= 1_000:
        return f"{size / 1_000:.0f} KB"
    return f"{size} B"
