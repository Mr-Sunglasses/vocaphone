from __future__ import annotations

import json

import httpx
import pytest
from conftest import TOKEN

from app.pairing import decode_pairing_payload


@pytest.mark.asyncio
async def test_pairing_endpoints_require_auth(client: httpx.AsyncClient) -> None:
    assert (await client.get("/v1/admin/pairing")).status_code == 401
    assert (await client.get("/v1/admin/pairing/qr.svg")).status_code == 401


@pytest.mark.asyncio
async def test_pairing_payload_and_qr(
    client: httpx.AsyncClient,
    authorization: dict[str, str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("LOCALFLOW_PUBLIC_URL", "http://192.168.1.75:8765")
    response = await client.get("/v1/admin/pairing", headers=authorization)
    assert response.status_code == 200
    body = response.json()
    assert body["url"] == "http://192.168.1.75:8765"
    assert body["version"] == 1
    decoded = decode_pairing_payload(body["payload"])
    assert decoded.url == "http://192.168.1.75:8765"
    assert decoded.token == TOKEN
    assert TOKEN not in json.dumps({k: v for k, v in body.items() if k != "payload"})

    qr = await client.get(
        "/v1/admin/pairing/qr.svg",
        headers=authorization,
        params={"url": "http://192.168.1.75:8765"},
    )
    assert qr.status_code == 200
    assert "svg" in qr.headers["content-type"]
    assert b"<svg" in qr.content.lower() or b"path" in qr.content.lower()
    assert len(qr.content) > 200

    partial = await client.get("/ui/partials/pairing", headers=authorization)
    assert partial.status_code == 200
    assert "pairing-qr" in partial.text
    assert "192.168.1.75" in partial.text
    # QR is inlined so the browser never needs an unauthenticated <img> fetch.
    assert "<svg" in partial.text.lower()


@pytest.mark.asyncio
async def test_pairing_accepts_bare_tailscale_address(
    client: httpx.AsyncClient,
    authorization: dict[str, str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("LOCALFLOW_PUBLIC_URL", "http://192.168.1.75:8765")

    partial = await client.get(
        "/ui/partials/pairing",
        headers=authorization,
        params={"url": "100.101.102.103"},
    )
    assert partial.status_code == 200
    assert "http://100.101.102.103:8765" in partial.text

    api = await client.get(
        "/v1/admin/pairing",
        headers=authorization,
        params={"url": "100.101.102.103"},
    )
    assert api.status_code == 200
    body = api.json()
    assert body["url"] == "http://100.101.102.103:8765"
    decoded = decode_pairing_payload(body["payload"])
    assert decoded.url == "http://100.101.102.103:8765"
