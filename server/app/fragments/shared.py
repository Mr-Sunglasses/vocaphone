from __future__ import annotations

from html import escape


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
