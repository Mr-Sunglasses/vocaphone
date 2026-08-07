from __future__ import annotations

from html import escape

from app.config import WILDCARD_BIND_HOSTS, format_host_port, local_webui_url
from app.fragments.shared import _facts, _format_bytes, _format_latency, _format_uptime
from app.schemas import AdminStatusResponse, OperationalMetricsStatus, ReadinessStatus


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
