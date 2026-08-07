from __future__ import annotations

from typing import Literal

from app.context import BOOTSTRAP_TOKEN_ID, GatewayContext
from app.errors import APIProblem
from app.fragments.pairing import pairing_fragment
from app.pairing import (
    discover_gateway_base_urls,
    encode_pairing_payload,
    is_ambient_lan_address,
    normalize_gateway_input,
    primary_gateway_base_url,
    qr_svg_for_payload,
)


def resolve_pairing_token(
    ctx: GatewayContext, token_id: str | None
) -> tuple[str, str, Literal["ok", "stale", "unknown"], str | None]:
    """Return (resolved_id, plaintext, status, requested_label).

    `stale` means the token still exists (see it under Settings) but this
    process never cached its plaintext — normally because it was created
    before the gateway last restarted. `unknown` means no such token
    exists at all (typically already revoked). Both fall back to the
    bootstrap token for the QR actually shown; only `stale` can be fixed
    by rotating the token to give it a fresh, displayable secret.
    """
    if token_id and token_id != BOOTSTRAP_TOKEN_ID:
        cached = ctx.token_store.cached_plaintext(token_id)
        if cached is not None:
            return token_id, cached, "ok", None
        existing = ctx.token_store.get(token_id)
        if existing is not None:
            return BOOTSTRAP_TOKEN_ID, ctx.settings.token, "stale", existing.label
        return BOOTSTRAP_TOKEN_ID, ctx.settings.token, "unknown", None
    return BOOTSTRAP_TOKEN_ID, ctx.settings.token, "ok", None


def pairing_token_options(ctx: GatewayContext) -> list[tuple[str, str]]:
    cached_ids = {token.id for token in ctx.token_store.cached_entries()}
    options = [(BOOTSTRAP_TOKEN_ID, "Bootstrap token")]
    options.extend(
        (
            token.id,
            token.label if token.id in cached_ids else f"{token.label} (paired; no live QR)",
        )
        for token in reversed(ctx.token_store.all())
    )
    return options


def forget_stale_lan_addresses(ctx: GatewayContext, discovered: list[str]) -> None:
    """Drop any remembered LAN/tailnet IP no longer part of fresh discovery.

    A bare LAN or Tailscale IP reflects whichever network the gateway was
    on when it was picked; keeping it around after switching Wi-Fi just
    clutters the address list and dropdown with a dead entry. Hostnames
    (MagicDNS names, custom domains) and public IPs are never touched —
    the user chose those deliberately and they aren't tied to one network.
    """
    if ctx.engine_manager is None:
        return
    pairing_config = ctx.pairing_config
    changed = False
    if (
        pairing_config.pairing_url
        and pairing_config.pairing_url not in discovered
        and is_ambient_lan_address(pairing_config.pairing_url)
    ):
        pairing_config.pairing_url = None
        changed = True
    remaining = [
        url
        for url in pairing_config.pairing_urls
        if url in discovered or not is_ambient_lan_address(url)
    ]
    if len(remaining) != len(pairing_config.pairing_urls):
        pairing_config.pairing_urls = remaining
        changed = True
    if changed:
        pairing_config.save(ctx.config_path)


def pairing_html(
    ctx: GatewayContext,
    selected_url: str | None = None,
    token_id: str | None = None,
    *,
    persist: bool = False,
) -> str:
    pairing_config = ctx.pairing_config
    discovered = discover_gateway_base_urls(ctx.settings.port)
    forget_stale_lan_addresses(ctx, discovered)
    candidates = list(discovered)
    for saved in pairing_config.pairing_urls:
        if saved not in candidates:
            candidates.append(saved)
    selected: str | None
    if selected_url:
        try:
            selected = normalize_gateway_input(selected_url, ctx.settings.port)
        except ValueError:
            selected = pairing_config.pairing_url or primary_gateway_base_url(ctx.settings.port)
        else:
            if selected not in candidates:
                candidates = [selected, *candidates]
            if persist and ctx.engine_manager is not None:
                changed = pairing_config.pairing_url != selected
                if selected not in discovered and selected not in pairing_config.pairing_urls:
                    pairing_config.pairing_urls.append(selected)
                    changed = True
                if changed:
                    pairing_config.pairing_url = selected
                    pairing_config.save(ctx.config_path)
    else:
        selected = pairing_config.pairing_url or primary_gateway_base_url(ctx.settings.port)
        if selected and selected not in candidates:
            candidates = [selected, *candidates]
    resolved_token_id, token, token_status, requested_label = resolve_pairing_token(ctx, token_id)
    redacted = (
        f"{token[:4]}…{token[-4:]} ({len(token)} characters)"
        if len(token) > 8
        else "•" * len(token)
    )
    qr_svg = ""
    if selected:
        qr_svg = qr_svg_for_payload(encode_pairing_payload(selected, token))
    return pairing_fragment(
        selected_url=selected,
        candidates=candidates,
        token_redacted=redacted,
        qr_svg=qr_svg,
        saved_urls=pairing_config.pairing_urls,
        token_options=pairing_token_options(ctx),
        selected_token_id=resolved_token_id,
        token_status=token_status,
        requested_token_id=token_id or "",
        requested_token_label=requested_label,
    )


def forget_pairing_url(ctx: GatewayContext, url: str) -> str:
    try:
        normalized = normalize_gateway_input(url, ctx.settings.port)
    except ValueError as error:
        raise APIProblem(400, "invalid_pairing_url", str(error)) from error
    pairing_config = ctx.pairing_config
    if ctx.engine_manager is not None and normalized in pairing_config.pairing_urls:
        pairing_config.pairing_urls.remove(normalized)
        if pairing_config.pairing_url == normalized:
            pairing_config.pairing_url = None
        pairing_config.save(ctx.config_path)
    return pairing_html(ctx)


def resolve_pairing_url(ctx: GatewayContext, url: str | None) -> str:
    candidates = discover_gateway_base_urls(ctx.settings.port)
    if url:
        try:
            return normalize_gateway_input(url, ctx.settings.port)
        except ValueError as error:
            raise APIProblem(400, "invalid_pairing_url", str(error)) from error
    if not candidates:
        raise APIProblem(
            503,
            "pairing_unavailable",
            "No phone-reachable gateway address was detected. Set LOCALFLOW_PUBLIC_URL and retry.",
        )
    return candidates[0]
