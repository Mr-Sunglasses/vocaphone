from __future__ import annotations

from datetime import datetime
from html import escape
from urllib.parse import quote

from app.config import WILDCARD_BIND_HOSTS, format_host_port, local_webui_url
from app.schemas import (
    AdminModelEntry,
    AdminStatusResponse,
    ConfigResponse,
    DeviceTokenEntry,
    EngineStatus,
    OperationalMetricsStatus,
    ReadinessStatus,
)

ENGINE_LABELS = {
    "auto": "Auto (recommended)",
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
    "handy": "Reuses the Handy app and its downloaded models. No download needed.",
    "whisper.cpp": "Runs local GGML models with the whisper-cli binary.",
    "whisperkit": "Runs Core ML models with whisperkit-cli on Apple Silicon Macs.",
    "faster-whisper": "Keeps a CTranslate2 model loaded; CPU INT8 is the Linux default.",
    "moonshine": "Fast, language-specific local models; compatible English tiers stream live.",
    "sherpa-onnx": "Compact INT8 CPU models for fast macOS and Linux transcription.",
    "mlx-audio": "Runs Apple-silicon-native MLX models with persistent loading.",
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


def overview_fragment(status: AdminStatusResponse, pairing_html: str = "") -> str:
    is_mac = status.system.os.startswith("Darwin")
    machine_label = "Mac" if is_mac else "server"
    ffmpeg_hint = "brew install ffmpeg" if is_mac else "Install FFmpeg with your package manager"
    engine_hint = (
        "brew install whisper-cpp or whisperkit-cli"
        if is_mac
        else "Install localflow-gateway[engines] (sherpa-onnx / faster-whisper) or use Docker"
    )
    checks = [
        ("Gateway token configured", status.setup.token_configured, ""),
        ("FFmpeg installed", status.setup.ffmpeg_available, ffmpeg_hint),
        (
            "Speech engine CLI installed",
            status.setup.engine_binary_available,
            engine_hint,
        ),
        ("Speech model available", status.setup.model_installed, "Open the Models tab"),
        ("Engine ready to transcribe", status.setup.engine_ready, "Select a downloaded model"),
    ]
    ready = (
        status.setup.token_configured
        and status.setup.ffmpeg_available
        and status.setup.engine_ready
    )
    listener = format_host_port(status.bind_host, status.port)
    local_url = local_webui_url(status.bind_host, status.port)
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
            (
                "CPU allocation",
                f"{status.system.effective_cpus:g} effective / "
                f"{status.system.logical_cpus} logical",
            ),
            ("Memory", f"{status.system.ram_gb:g} GB"),
            ("Accelerators", ", ".join(status.system.accelerators)),
            ("CPU features", ", ".join(status.system.cpu_features) or "standard"),
            ("Runtime", "container" if status.system.containerized else "host"),
            ("OS", f"{status.system.os} ({status.system.arch})"),
            ("Version", status.version),
        ]
    )
    rows = "".join(
        "<tr>"
        f"<td>{escape(dependency.name)}</td>"
        f'<td><span class="badge {"ok" if dependency.available else "missing"}">'
        f"{'installed' if dependency.available else 'missing'}</span></td>"
        f"<td><code>{escape(dependency.path or dependency.install_hint or '—')}</code></td>"
        "</tr>"
        for dependency in status.dependencies
    )
    if ready:
        next_steps = """
          <div class="ready-message">
            <span class="ready-icon" aria-hidden="true">✓</span>
            <div><strong>The gateway is ready for dictation.</strong>
              <p class="muted">Use the Test tab for a quick microphone check, then connect
                the phone app with this host's LAN or Tailscale URL and bearer token.</p></div>
          </div>
        """
    else:
        pending_steps = []
        if not status.setup.ffmpeg_available:
            pending_steps.append(f"{escape(ffmpeg_hint)}.")
        if not status.setup.engine_binary_available:
            pending_steps.append(f"{escape(engine_hint)}.")
        if not status.setup.model_installed:
            pending_steps.append(
                f"Open Models and download a model recommended for this {machine_label}."
            )
        if not status.setup.engine_ready:
            pending_steps.append("Select an installed model and confirm that the engine is ready.")
        next_steps = (
            '<ol class="steps">' + "".join(f"<li>{step}</li>" for step in pending_steps) + "</ol>"
        )
    exposure_notice = ""
    if status.bind_host in WILDCARD_BIND_HOSTS:
        firewall_hint = "Keep macOS Firewall on" if is_mac else "Keep the host firewall enabled"
        exposure_notice = f"""
          <div class="callout warning">
            <strong>Available on every network interface</strong>
            <span>The private API still requires the bearer token. {firewall_hint},
              use Tailscale for remote access, and do not expose this port to the internet.</span>
          </div>
        """
    return f"""
      <section class="status-hero {"ready" if ready else "attention"}">
        <div>
          <span class="eyebrow">Gateway status</span>
          <h2>{"Ready for dictation" if ready else "Setup needs attention"}</h2>
          <p>{escape(status.engine.name)} ·
            {"engine ready" if status.engine.ready else "engine unavailable"}</p>
        </div>
        <dl class="connection-facts">
          <div><dt>Listener</dt><dd>{escape(listener)}</dd></div>
          <div><dt>Open on this host</dt><dd>{escape(local_url)}</dd></div>
        </dl>
      </section>
      {exposure_notice}
      {operations_fragment(status.metrics, status.readiness)}
      {pairing_html}
      <div class="grid two">
        <div class="card">
          <h2>Setup checklist</h2>
          <ul class="checklist">{checklist}</ul>
        </div>
        <div class="card">
          <h2>This {machine_label}</h2>
          <dl class="facts">{facts}</dl>
        </div>
      </div>
      <div class="card">
        <h2>Dependencies</h2>
        <div class="table-scroll">
          <table class="table">
            <thead><tr><th>Tool</th><th>Status</th><th>Path / install</th></tr></thead>
            <tbody>{rows}</tbody>
          </table>
        </div>
      </div>
      <div class="card">
        <h2>Next steps</h2>
        {next_steps}
      </div>
    """


def operations_fragment(metrics: OperationalMetricsStatus, readiness: ReadinessStatus) -> str:
    average_latency = _format_latency(metrics.average_latency_ms)
    last_latency = _format_latency(metrics.last_latency_ms)
    warmup_labels = {
        "pending": ("Pending", "The startup warm-up has not run yet."),
        "warming": ("Warming", "The selected model is being primed."),
        "complete": (
            "Warm",
            f"{_format_bytes(readiness.warmed_bytes)} of model data prepared.",
        ),
        "unsupported": ("Ready", "This engine does not expose model prefetching."),
        "unavailable": ("Waiting", "Install or select a model to warm it."),
        "failed": ("Needs retry", "Warm-up failed; transcription can still retry."),
    }
    warmup_label, warmup_detail = warmup_labels[readiness.warmup_state]
    cards = "".join(
        [
            _metric_card("Uptime", _format_uptime(metrics.uptime_seconds), "Current process"),
            _metric_card(
                "Workload",
                f"{metrics.queue_depth} queued",
                f"{metrics.active_transcriptions} of {metrics.concurrency_limit} active",
            ),
            _metric_card(
                "Successful",
                str(metrics.successful_transcriptions),
                "Completed transcriptions",
                "success",
            ),
            _metric_card(
                "Failed",
                str(metrics.failed_transcriptions),
                f"{metrics.rejected_transcriptions} overload rejections",
                "failure" if metrics.failed_transcriptions else "",
            ),
            _metric_card("Average latency", average_latency, f"Last {last_latency}"),
            _metric_card("Model cache", warmup_label, warmup_detail, readiness.warmup_state),
            _metric_card(
                "Last inference",
                _format_latency(metrics.inference_ms),
                f"Normalize {_format_latency(metrics.normalization_ms)} · "
                f"load {_format_latency(metrics.model_load_ms)}",
            ),
            _metric_card(
                "Real-time factor",
                f"{metrics.real_time_factor:.2f}×" if metrics.real_time_factor is not None else "—",
                (
                    f"{_format_latency(metrics.audio_duration_ms)} audio · "
                    f"{metrics.peak_memory_mb:g} MB peak"
                    if metrics.peak_memory_mb is not None
                    else "Run a test to measure"
                ),
            ),
        ]
    )
    return f"""
      <section id="operations" class="operations"
               hx-get="/ui/partials/operations" hx-trigger="every 5s"
               hx-swap="outerHTML" aria-label="Gateway operations">
        <div class="section-heading compact">
          <div>
            <span class="eyebrow">Live operations</span>
            <h2>Since this server started</h2>
          </div>
          <span class="probe-age">Engine checked {readiness.probe_age_seconds:.1f}s ago</span>
        </div>
        <div class="operations-grid">
          {cards}
        </div>
      </section>
    """


def _metric_card(label: str, value: str, detail: str, css: str = "") -> str:
    class_name = f"metric-card {css}".strip()
    return (
        f'<article class="{class_name}"><span class="metric-label">{escape(label)}</span>'
        f'<strong class="metric-value">{escape(value)}</strong>'
        f'<span class="metric-detail">{escape(detail)}</span></article>'
    )


def models_fragment(entries: list[AdminModelEntry]) -> str:
    installed = sum(entry.state == "installed" for entry in entries)
    return f"""
      <div class="models-hero">
        <div>
          <span class="eyebrow">Private model library</span>
          <h2>Choose the voice engine for this server</h2>
          <p>Models stay on this machine. Standalone models work without the Handy app
            and can move with the Docker data volume.</p>
        </div>
        <div class="model-stats" aria-label="Model library summary">
          <span><strong>{installed}</strong> installed</span>
          <span><strong>{len(entries)}</strong> available</span>
        </div>
      </div>
      <div class="card models-library">
        <div class="card-header models-toolbar">
          <div>
            <h2>Available models</h2>
            <p class="muted">Recommendations are matched to this server's hardware.</p>
          </div>
          <button type="button" class="ghost small no-margin"
                  hx-get="/ui/partials/models-list"
                  hx-target="#models-list" hx-swap="innerHTML">Refresh</button>
        </div>
        <div id="models-list" aria-live="polite">
          {models_list_fragment(entries)}
        </div>
      </div>
      <div class="card">
        <h2>Bring your own Whisper model</h2>
        <p class="muted">Paste a direct HTTPS link to a compatible <code>.bin</code> or
          <code>.gguf</code> file. It will run through the standalone engine.</p>
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
        cards = "".join(_model_card(item) for item in items)
        parts.append(
            f'<section class="model-group"><div class="model-group-heading">'
            f"<h3>{title}</h3><span>{len(items)} models</span></div>"
            f'<div class="model-grid">{cards}</div></section>'
        )
    return "".join(parts) or '<p class="empty-state">No models are available.</p>'


def _model_card(entry: AdminModelEntry) -> str:
    encoded_id = quote(entry.id, safe="")
    badges = ""
    if entry.recommended:
        badges += '<span class="badge recommended">recommended</span>'
    if entry.active:
        badges += '<span class="badge active">active</span>'
    if entry.supports_streaming:
        badges += '<span class="badge streaming">live</span>'
    if not entry.commercial_use:
        badges += '<span class="badge personal">personal use</span>'

    if entry.state == "downloading":
        percent = round((entry.progress or 0) * 100)
        downloaded = _format_bytes(entry.downloaded_bytes or 0)
        total = _format_bytes(entry.total_bytes or 0)
        action = (
            f'<div class="progress" role="progressbar" aria-valuemin="0" aria-valuemax="100"'
            f' aria-valuenow="{percent}"><div class="bar" style="width:{percent}%"></div></div>'
            f'<span class="muted small progress-copy">'
            f"{percent}% · {downloaded} / {total}</span>"
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
            f' hx-confirm="Delete {escape(entry.label)} from this server?"'
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

    return f"""
      <article class="model-card" data-model-id="{escape(entry.id, quote=True)}"
               data-state="{entry.state}">
        <div class="model-card-top">
          <span class="model-family">{escape(entry.family)}</span>
          <div class="model-badges">{badges}</div>
        </div>
        <h4>{escape(entry.label)}</h4>
        <p class="model-description">{escape(entry.description)}</p>
        <div class="model-meta">
          <span>{_format_bytes(entry.size_bytes)}</span>
          <span>{escape(entry.languages)}</span>
          <span>{escape(entry.quality)}</span>
        </div>
        <div class="model-card-footer">
          <span class="model-source">{escape(entry.source)} · {escape(entry.license_name)}</span>
          <div class="actions">{action}</div>
        </div>
      </article>
    """


def pairing_fragment(
    *,
    selected_url: str | None,
    candidates: list[str],
    token_redacted: str,
    qr_svg: str = "",
    saved_urls: list[str],
    token_options: list[tuple[str, str]],
    selected_token_id: str,
    token_status: str = "ok",
    requested_token_id: str = "",
    requested_token_label: str | None = None,
) -> str:
    """Authenticated phone-pairing card with QR for the selected gateway URL.

    The SVG is inlined so the browser does not need a second request (img tags
    cannot attach the WebUI bearer header). `token_options` lists the bootstrap
    token plus every device token, marking ones this process cannot currently
    display for QR purposes — only cached plaintexts can be encoded. That
    device's own pairing is completely unaffected either way: the phone keeps
    authenticating with its already-scanned secret regardless of whether this
    process can still show it. `token_status` explains why the shown token
    differs from what was asked for: `stale` means the requested device token
    still works fine but this process cannot redisplay its secret (typically
    after a restart) — rotating is optional and only needed to get a fresh,
    viewable QR, for example to re-pair a lost phone. `unknown` means it no
    longer exists at all (typically already revoked).
    """
    if not selected_url:
        return """
      <div class="card" id="pairing-card">
        <h2>Pair phone app</h2>
        <p class="muted">No phone-reachable address was detected. Set
          <code>LOCALFLOW_PUBLIC_URL</code> to the URL the phone should use
          (for example <code>http://192.168.1.20:8765</code>), then reload.</p>
      </div>
        """
    options = "".join(
        f'<option value="{escape(url)}"{" selected" if url == selected_url else ""}>'
        f"{escape(url)}</option>"
        for url in candidates
    )
    token_option_html = "".join(
        f'<option value="{escape(token_id)}"{" selected" if token_id == selected_token_id else ""}>'
        f"{escape(label)}</option>"
        for token_id, label in token_options
    )
    selected_token_label = next(
        (label for token_id, label in token_options if token_id == selected_token_id),
        "Bootstrap token",
    )
    if token_status == "stale":
        stale_label = escape(requested_token_label or "That device token")
        unavailable_notice = f"""
          <div class="callout compact">
            <span><strong>{stale_label} is still paired and working normally.</strong> A server
              restart just means this session can no longer redisplay its secret — by design,
              it's never stored anywhere it could be recovered from. Showing the bootstrap
              token instead; no action is needed unless you actually want a fresh QR (for
              example, to re-pair a lost phone).</span>
            <form hx-post="/ui/partials/pairing/tokens/{quote(requested_token_id, safe="")}/rotate"
                  hx-target="#pairing-card" hx-swap="outerHTML">
              <input type="hidden" name="url" value="{escape(selected_url)}" />
              <button type="submit" class="ghost small">Rotate &amp; show a new QR</button>
            </form>
            <span class="muted small">Only rotate if you need that: it immediately retires the
              current secret, and the device using it will have to be paired again.</span>
          </div>
        """
    elif token_status == "unknown":
        unavailable_notice = """
          <div class="callout warning compact">
            <span>That device token no longer exists. It may have been revoked. Showing the
              bootstrap token instead — create a new device token below for a fresh QR.</span>
          </div>
        """
    else:
        unavailable_notice = ""
    saved_rows = "".join(
        f"<li><code>{escape(url)}</code>"
        f'<button type="button" class="ghost small danger"'
        f' hx-delete="/ui/partials/pairing?url={quote(url, safe="")}"'
        f' hx-target="#pairing-card" hx-swap="outerHTML"'
        f' hx-confirm="Remove {escape(url)} from saved addresses?">Remove</button></li>'
        for url in saved_urls
    )
    saved_section = (
        f"""
            <div class="pairing-saved">
              <span>Saved addresses</span>
              <ul>{saved_rows}</ul>
            </div>
        """
        if saved_urls
        else ""
    )
    # Strip XML declaration for clean inline embedding.
    inline_svg = qr_svg
    if inline_svg.lstrip().startswith("<?xml"):
        inline_svg = inline_svg.split("?>", 1)[-1].lstrip()
    return f"""
      <div class="card" id="pairing-card">
        <h2>Pair phone app</h2>
        <p class="muted">Scan this QR in Local Flow on iPhone or Android to fill the gateway
          address and bearer token. Keep the WebUI private — the code includes the
          live token.</p>
        <div class="pairing-layout">
          <div class="pairing-qr" role="img"
               aria-label="Pairing QR code for {escape(selected_url)}">{inline_svg}</div>
          <div class="pairing-meta">
            {unavailable_notice}
            <div class="pairing-url-form">
              <label><span>Address encoded in the QR</span>
                <select name="url"
                        hx-get="/ui/partials/pairing"
                        hx-target="#pairing-card"
                        hx-swap="outerHTML"
                        hx-trigger="change"
                        hx-include="this,[name='token_id']">
                  {options}
                </select>
              </label>
              <label><span>Token to encode</span>
                <select name="token_id"
                        hx-get="/ui/partials/pairing"
                        hx-target="#pairing-card"
                        hx-swap="outerHTML"
                        hx-trigger="change"
                        hx-include="this,[name='url']">
                  {token_option_html}
                </select>
              </label>
              <form hx-get="/ui/partials/pairing" hx-target="#pairing-card" hx-swap="outerHTML">
                <input type="hidden" name="token_id" value="{escape(selected_token_id)}" />
                <label><span>Or enter your own address (e.g. Tailscale IP)</span>
                  <div class="row">
                    <input name="url" type="text"
                           placeholder="100.101.102.103 or phone.tailnet-name.ts.net" />
                    <button type="submit" class="ghost small">Use this address</button>
                  </div>
                </label>
              </form>
              <form hx-post="/ui/partials/pairing/tokens" hx-target="#pairing-card"
                    hx-swap="outerHTML">
                <input type="hidden" name="url" value="{escape(selected_url)}" />
                <label><span>Or pair a new device with its own token</span>
                  <div class="row">
                    <input name="label" type="text" required maxlength="100"
                           placeholder="e.g. Kanishk&#39;s iPhone" />
                    <button type="submit" class="ghost small">Create &amp; show QR</button>
                  </div>
                </label>
              </form>
              {saved_section}
            </div>
            <dl class="facts">
              <div><dt>Gateway URL</dt><dd><code>{escape(selected_url)}</code></dd></div>
              <div><dt>Token</dt>
                <dd><code>{escape(token_redacted)}</code>
                  ({escape(selected_token_label)})</dd></div>
            </dl>
            <p class="muted small">Prefer the Wi‑Fi LAN address when the phone is on
              the same network. Use a Tailscale MagicDNS name when both devices are
              on the tailnet. Override discovery with
              <code>LOCALFLOW_PUBLIC_URL</code>. Device tokens created here also appear
              under Settings, where they can be revoked.</p>
          </div>
        </div>
      </div>
    """


def tokens_fragment(
    entries: list[DeviceTokenEntry], *, new_token: tuple[str, str] | None = None
) -> str:
    reveal = ""
    if new_token is not None:
        label, plaintext = new_token
        reveal = f"""
          <div class="callout success">
            <strong>New secret for {escape(label)}</strong>
            <span>Copy this token now &mdash; it will not be shown again. Paste it with the
              gateway address into that device's manual "Gateway address and token" fields.</span>
            <div class="row">
              <code id="new-token-value">{escape(plaintext)}</code>
              <button type="button" class="ghost small" id="copy-new-token">Copy</button>
            </div>
          </div>
        """
    rows = "".join(
        "<tr>"
        f"<td>{escape(entry.label)}</td>"
        f"<td>{escape(_format_created(entry.created_at))}</td>"
        "<td>"
        + (
            '<button type="button" class="ghost small"'
            f' hx-post="/ui/partials/tokens/{quote(entry.id, safe="")}/rotate"'
            ' hx-target="#tokens-card" hx-swap="outerHTML"'
            f' hx-confirm="Give {escape(entry.label)} a new secret? Its previous token stops '
            'working immediately.">Regenerate</button>'
            '<button type="button" class="ghost small danger"'
            f' hx-delete="/ui/partials/tokens/{quote(entry.id, safe="")}"'
            ' hx-target="#tokens-card" hx-swap="outerHTML"'
            f' hx-confirm="Revoke {escape(entry.label)}? Any device using only this token '
            'loses access immediately.">Revoke</button>'
            if entry.revocable
            else '<span class="muted small">Not revocable here</span>'
        )
        + "</td></tr>"
        for entry in entries
    )
    return f"""
      <div class="card" id="tokens-card">
        <h2>Paired device tokens</h2>
        <p class="muted">Give each phone its own bearer token so losing one device only means
          revoking that device's token instead of rotating everyone else's. Devices already
          paired with the bootstrap token keep working until you re-pair them with one of
          these.</p>
        {reveal}
        <div class="table-scroll">
          <table class="table">
            <thead><tr><th>Label</th><th>Created</th><th></th></tr></thead>
            <tbody>{rows}</tbody>
          </table>
        </div>
        <form hx-post="/ui/partials/tokens" hx-target="#tokens-card" hx-swap="outerHTML">
          <div class="row">
            <input name="label" type="text" required maxlength="100"
                   placeholder="e.g. Kanishk&#39;s iPhone" />
            <button type="submit" class="primary">Create token</button>
          </div>
        </form>
      </div>
    """


def _format_created(value: datetime | None) -> str:
    return "—" if value is None else value.strftime("%Y-%m-%d %H:%M UTC")


def settings_fragment(
    config: ConfigResponse,
    paths: list[tuple[str, str]],
    bind_host: str,
    port: int,
    tokens_html: str,
) -> str:
    options = "".join(
        f'<option value="{escape(value)}"{" selected" if value == config.engine else ""}>'
        f"{escape(ENGINE_LABELS.get(value, value))}</option>"
        for value in config.available_engines
    )
    hint = escape(ENGINE_HINTS.get(config.engine, ""))
    facts = _facts(paths)
    listener = escape(format_host_port(bind_host, port))
    local_url = escape(local_webui_url(bind_host, port))
    device_options = _select_options(
        [("auto", "Auto"), ("cpu", "CPU"), ("cuda", "NVIDIA CUDA")],
        config.compute_device,
    )
    precision_options = _select_options(
        [
            ("auto", "Auto (INT8 CPU / FP16 CUDA)"),
            ("int8", "INT8"),
            ("int8_float16", "INT8 + FP16"),
            ("float16", "FP16"),
            ("float32", "FP32"),
        ],
        config.compute_type,
    )
    exposure_notice = ""
    if bind_host in WILDCARD_BIND_HOSTS:
        exposure_notice = """
          <div class="callout warning compact">
            <strong>All-interface listener</strong>
            <span>Devices on reachable networks can contact the gateway. They still need
              the bearer token for transcription and administration.</span>
          </div>
        """
    return f"""
      <div class="card">
        <h2>Speech engine</h2>
        <p class="muted">Choose which local engine transcribes incoming audio.
          Selecting a model in the Models tab sets this automatically.</p>
        <form hx-put="/ui/partials/config" hx-target="#engine-result" hx-swap="innerHTML">
          <div class="settings-grid">
            <label><span>Engine</span>
            <select name="engine">{options}</select>
            </label>
            <label><span>Compute device</span>
              <select name="compute_device">
                {device_options}
              </select>
            </label>
            <label><span>Precision</span>
              <select name="compute_type">
                {precision_options}
              </select>
            </label>
            <label><span>CPU threads</span>
              <input name="cpu_threads" type="number" min="0" max="256"
                     value="{config.cpu_threads}" aria-describedby="threads-hint" />
            </label>
          </div>
          <p id="threads-hint" class="muted small">
            Use 0 for an automatic, conservative thread count.
            INT8 is normally fastest on Linux CPUs.</p>
          <div class="row">
            <button type="submit" class="primary">Apply</button>
          </div>
        </form>
        <p id="engine-result" class="muted">{hint}</p>
      </div>
      <div class="card">
        <h2>Network</h2>
        <dl class="facts">
          <dt>Listener</dt><dd>{listener}</dd>
          <dt>Open on this host</dt><dd>{local_url}</dd>
        </dl>
        {exposure_notice}
      </div>
      <div class="card">
        <h2>Storage &amp; configuration</h2>
        <dl class="facts">{facts}</dl>
      </div>
      <div class="card">
        <h2>Diagnostics</h2>
        <p class="muted">Download a redacted snapshot of this gateway's setup, dependencies,
          hardware, and operational counters &mdash; useful when attaching to a bug report.
          It never includes the bearer token, recordings, transcripts, or session
          identifiers.</p>
        <button id="download-diagnostics" type="button" class="ghost">Download diagnostics</button>
      </div>
      {tokens_html}
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
        f"{' ready' if engine.ready else ' not ready'}</span> "
        f"{escape(message)}{engine_pill_oob(engine)}"
    )


def test_fragment(maximum_duration_seconds: int) -> str:
    return f"""
      <div class="card">
        <h2>Try your pipeline</h2>
        <p class="muted">Record a short clip with this browser's microphone. The audio is
          normalized with FFmpeg and transcribed by the active engine &mdash; exactly like
          an iPhone dictation.</p>
        <div class="row" id="recorder-controls"
             data-maximum-seconds="{maximum_duration_seconds}">
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
          <select id="test-runs" aria-label="Benchmark repetitions">
            <option value="1">1 run</option>
            <option value="3">3-run benchmark</option>
          </select>
          <button id="record-toggle" type="button" class="primary">Start recording</button>
          <span id="record-timer" class="record-timer hidden">0:00</span>
        </div>
        <p id="record-status" class="muted" aria-live="polite"></p>
        <div id="test-result" class="result hidden">
          <div class="result-header">
            <h3>Transcript</h3>
            <button id="copy-transcript" type="button" class="ghost small">Copy</button>
          </div>
          <p id="test-transcript"></p>
          <p id="test-meta" class="muted"></p>
          <div id="benchmark-metrics" class="benchmark-grid" aria-label="Pipeline benchmark">
            <div><span>Total</span><strong id="benchmark-total">—</strong></div>
            <div><span>Normalize</span><strong id="benchmark-normalize">—</strong></div>
            <div><span>Model load</span><strong id="benchmark-load">—</strong></div>
            <div><span>Inference</span><strong id="benchmark-inference">—</strong></div>
            <div><span>RTF</span><strong id="benchmark-rtf">—</strong></div>
            <div><span>Peak memory</span><strong id="benchmark-memory">—</strong></div>
          </div>
        </div>
        <p id="test-error" class="error hidden" role="alert"></p>
      </div>
    """


def error_fragment(message: str) -> str:
    return f'<p class="error">{escape(message)}</p>'


def _facts(items: list[tuple[str, str]]) -> str:
    return "".join(f"<dt>{escape(label)}</dt><dd>{escape(value)}</dd>" for label, value in items)


def _select_options(items: list[tuple[str, str]], selected: str) -> str:
    return "".join(
        f'<option value="{escape(value)}"{" selected" if value == selected else ""}>'
        f"{escape(label)}</option>"
        for value, label in items
    )


def _format_bytes(size: int) -> str:
    if size >= 1_000_000_000:
        return f"{size / 1_000_000_000:.1f} GB"
    if size >= 1_000_000:
        return f"{size / 1_000_000:.0f} MB"
    if size >= 1_000:
        return f"{size / 1_000:.0f} KB"
    return f"{size} B"


def _format_uptime(seconds: int) -> str:
    days, remainder = divmod(max(0, seconds), 86_400)
    hours, remainder = divmod(remainder, 3_600)
    minutes, remaining_seconds = divmod(remainder, 60)
    if days:
        return f"{days}d {hours}h"
    if hours:
        return f"{hours}h {minutes}m"
    if minutes:
        return f"{minutes}m {remaining_seconds}s"
    return f"{remaining_seconds}s"


def _format_latency(milliseconds: int | None) -> str:
    if milliseconds is None:
        return "—"
    if milliseconds >= 1_000:
        return f"{milliseconds / 1_000:.1f}s"
    return f"{milliseconds}ms"
