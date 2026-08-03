from __future__ import annotations

import json

import pytest

from app.pairing import (
    PAIRING_VERSION,
    decode_pairing_payload,
    encode_pairing_payload,
    normalize_gateway_input,
    primary_gateway_base_url,
    qr_svg_for_payload,
)


def test_round_trip_encode_decode() -> None:
    raw = encode_pairing_payload(
        "http://192.168.1.20:8765/",
        "test-token-with-at-least-thirty-two-characters",
    )
    data = json.loads(raw)
    assert data["v"] == PAIRING_VERSION
    assert data["url"] == "http://192.168.1.20:8765"
    assert data["token"] == "test-token-with-at-least-thirty-two-characters"
    decoded = decode_pairing_payload(raw)
    assert decoded.url == "http://192.168.1.20:8765"
    assert decoded.token == "test-token-with-at-least-thirty-two-characters"


def test_decode_rejects_garbage() -> None:
    with pytest.raises(ValueError, match="not valid JSON"):
        decode_pairing_payload("not-json")
    with pytest.raises(ValueError, match="empty"):
        decode_pairing_payload("   ")
    with pytest.raises(ValueError, match="version"):
        decode_pairing_payload(
            '{"v":99,"url":"http://192.168.1.1:8765",'
            '"token":"test-token-with-at-least-thirty-two-characters"}'
        )
    with pytest.raises(ValueError, match="URL"):
        decode_pairing_payload('{"v":1,"token":"test-token-with-at-least-thirty-two-characters"}')
    with pytest.raises(ValueError, match="token"):
        decode_pairing_payload('{"v":1,"url":"http://192.168.1.1:8765","token":""}')


def test_encode_rejects_public_credentials_and_query() -> None:
    with pytest.raises(ValueError, match="credentials"):
        encode_pairing_payload(
            "http://user:pass@192.168.1.1:8765",
            "test-token-with-at-least-thirty-two-characters",
        )
    with pytest.raises(ValueError, match="query"):
        encode_pairing_payload(
            "http://192.168.1.1:8765?x=1",
            "test-token-with-at-least-thirty-two-characters",
        )


def test_qr_svg_contains_path_and_is_svg() -> None:
    payload = encode_pairing_payload(
        "http://192.168.1.75:8765",
        "test-token-with-at-least-thirty-two-characters",
    )
    svg = qr_svg_for_payload(payload)
    assert svg.lstrip().startswith("<?xml") or "<svg" in svg
    assert "path" in svg.lower() or "rect" in svg.lower()
    assert len(svg) > 200


def test_primary_gateway_base_url_prefers_override(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("LOCALFLOW_PUBLIC_URL", "http://homelab.example:8765")
    assert primary_gateway_base_url(8765) == "http://homelab.example:8765"


def test_normalize_gateway_input_adds_scheme_and_default_port() -> None:
    assert normalize_gateway_input("100.101.102.103", 8765) == "http://100.101.102.103:8765"


def test_normalize_gateway_input_keeps_explicit_port() -> None:
    assert normalize_gateway_input("100.101.102.103:9000", 8765) == "http://100.101.102.103:9000"


def test_normalize_gateway_input_accepts_tailscale_hostname() -> None:
    assert (
        normalize_gateway_input("phone.tailnet-name.ts.net", 8765)
        == "http://phone.tailnet-name.ts.net:8765"
    )


def test_normalize_gateway_input_passes_through_full_url() -> None:
    assert normalize_gateway_input("http://192.168.1.5:8765", 8765) == "http://192.168.1.5:8765"


def test_normalize_gateway_input_rejects_empty() -> None:
    with pytest.raises(ValueError, match="empty"):
        normalize_gateway_input("   ", 8765)
