from __future__ import annotations

from html import escape
from urllib.parse import quote

from app.catalog import DEFAULT_CATALOG, LANGUAGE_NAMES
from app.fragments.engine import ENGINE_LABELS
from app.fragments.shared import _format_bytes
from app.schemas import AdminModelEntry

# Every action that re-renders the model list sends both filters, so downloading
# or selecting a model never silently resets the view.
MODEL_FILTER_INPUTS = "#installed-only-toggle, #language-filter"


def models_fragment(entries: list[AdminModelEntry]) -> str:
    installed = sum(entry.state == "installed" for entry in entries)
    return f"""
      <div class="models-hero">
        <div>
          <span class="eyebrow">Private model library</span>
          <h2>Choose the voice engine for this server</h2>
          <p>Models stay on this machine. The VocaMac and Handy apps are optional
            and Mac-only: standalone models work without either, on any host, and
            can move with the Docker data volume.</p>
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
          <div class="models-toolbar-actions">
            <label class="sr-only" for="language-filter">Filter models by language</label>
            <select id="language-filter" name="language" class="language-filter"
                    hx-get="/ui/partials/models-list" hx-include="{MODEL_FILTER_INPUTS}"
                    hx-target="#models-list" hx-swap="innerHTML" hx-trigger="change">
              <option value="">All languages</option>
              {_language_filter_options()}
            </select>
            <label class="filter-toggle" for="installed-only-toggle">
              <input type="checkbox" id="installed-only-toggle" name="installed_only"
                     value="true" class="sr-only" hx-get="/ui/partials/models-list"
                     hx-include="{MODEL_FILTER_INPUTS}"
                     hx-target="#models-list" hx-swap="innerHTML" hx-trigger="change" />
              Installed only
            </label>
            <button type="button" class="ghost small no-margin"
                    hx-get="/ui/partials/models-list" hx-include="{MODEL_FILTER_INPUTS}"
                    hx-target="#models-list" hx-swap="innerHTML">Refresh</button>
          </div>
        </div>
        <div id="models-list" aria-live="polite">
          {models_list_fragment(entries)}
        </div>
      </div>
      <div class="card">
        <h2>Bring your own Whisper model</h2>
        <p class="muted">Paste a direct HTTPS link to a compatible <code>.bin</code> or
          <code>.gguf</code> file. It will run through the standalone engine.</p>
        <form hx-post="/ui/partials/models/custom" hx-include="{MODEL_FILTER_INPUTS}"
              hx-target="#models-list" hx-swap="innerHTML">
          <div class="row">
            <input name="url" type="url" required
                   placeholder="https://huggingface.co/&hellip;/resolve/main/model.gguf" />
            <button type="submit" class="primary">Download</button>
          </div>
        </form>
      </div>
    """


def _language_filter_options() -> str:
    """Only languages some model actually covers, so the filter never has a
    dead option. Whisper's set dominates, but Dolphin contributes the South and
    Southeast Asian languages Whisper lacks."""
    covered = {code for model in DEFAULT_CATALOG for code in model.language_codes}
    named = sorted((LANGUAGE_NAMES.get(code, code), code) for code in covered)
    return "".join(
        f'<option value="{escape(code, quote=True)}">{escape(name)}</option>'
        for name, code in named
    )


def models_list_fragment(
    entries: list[AdminModelEntry], installed_only: bool = False, language: str = ""
) -> str:
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
    if parts:
        return _dictation_language_hint(entries, language) + "".join(parts)
    if installed_only and language:
        name = escape(LANGUAGE_NAMES.get(language, language))
        return (
            f'<p class="empty-state">No downloaded model covers {name}. '
            "Turn off &ldquo;Installed only&rdquo; to find one to download.</p>"
        )
    if language:
        name = escape(LANGUAGE_NAMES.get(language, language))
        return f'<p class="empty-state">No model in the catalog covers {name}.</p>'
    if installed_only:
        return (
            '<p class="empty-state">No models downloaded yet. '
            "Turn off &ldquo;Installed only&rdquo; to browse the catalog.</p>"
        )
    return '<p class="empty-state">No models are available.</p>'


def _dictation_language_hint(entries: list[AdminModelEntry], language: str) -> str:
    """Warn when a filtered list mixes pinnable and auto-detecting models.

    Testing showed every auto-detecting model returns the wrong writing system on
    a short phrase — "ठीक है" came back as Chinese from both Dolphin and
    Qwen3-ASR. Pinning the language fixes it outright, so someone filtering for
    their language needs to know which half of the list to trust for dictation,
    which is mostly short phrases.
    """
    if not language:
        return ""
    automatic = [entry for entry in entries if entry.detects_language_automatically]
    pinnable = [entry for entry in entries if not entry.detects_language_automatically]
    if not automatic or not pinnable:
        return ""
    name = escape(LANGUAGE_NAMES.get(language, language))
    return (
        '<div class="callout warning models-language-hint">'
        f"<strong>Choosing a model for {name}</strong>"
        "<span>The models badged <em>auto language</em> decide the language themselves. "
        "They are strong on full sentences but return the wrong alphabet entirely on a "
        "short phrase, which is most of dictation. Prefer one of the other "
        f"{len(pinnable)} models here, which are told to transcribe {name}.</span>"
        "</div>"
    )


def _language_disclosure(entry: AdminModelEntry) -> str:
    """Name the languages behind a summary like "25 European languages".

    A `<details>` rather than an always-open list: the summary line is what people
    scan, and forty language names on every card would bury everything else. It
    needs no JavaScript, stays keyboard-accessible, and is searchable by the
    browser's own find-in-page once opened.
    """
    # A single-language model needs no disclosure: the "English only" summary
    # beside it already says everything the list would.
    if len(entry.language_names) < 2:
        return ""
    names = ", ".join(escape(name) for name in entry.language_names)
    note = (
        " This model chooses the language itself, so these are the languages it "
        "transcribes well, not a list you can pick from."
        if entry.detects_language_automatically
        else ""
    )
    return f"""
        <details class="model-languages">
          <summary>{len(entry.language_names)} languages</summary>
          <p class="model-language-list">{names}.{escape(note)}</p>
        </details>
    """


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
    if entry.detects_language_automatically:
        badges += (
            '<span class="badge auto-language" title="This model decides the language itself.'
            ' The language chosen in the app does not constrain it.">auto language</span>'
        )

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
            f' hx-include="{MODEL_FILTER_INPUTS}"'
            f' hx-target="#models-list" hx-swap="innerHTML">Cancel</button>'
        )
    elif entry.state == "installed":
        select_button = (
            ""
            if entry.active
            else (
                f'<button class="primary small"'
                f' hx-post="/ui/partials/models/{encoded_id}/select"'
                f' hx-include="{MODEL_FILTER_INPUTS}"'
                f' hx-target="#models-list" hx-swap="innerHTML">Select</button>'
            )
        )
        action = (
            f"{select_button}"
            f'<button class="ghost small danger"'
            f' hx-delete="/ui/partials/models/{encoded_id}"'
            f' hx-include="{MODEL_FILTER_INPUTS}"'
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
            f' hx-include="{MODEL_FILTER_INPUTS}"'
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
        {_language_disclosure(entry)}
        <div class="model-card-footer">
          <span class="model-source">{escape(entry.source)} · {escape(entry.license_name)}</span>
          <div class="actions">{action}</div>
        </div>
      </article>
    """
