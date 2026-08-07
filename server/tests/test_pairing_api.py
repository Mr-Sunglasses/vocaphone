from __future__ import annotations

import json
from pathlib import Path

import httpx
import pytest
from conftest import TOKEN, FakeEngine, FakeNormalizer

from app.config import Settings
from app.main import create_app
from app.model_manager import ModelManager
from app.pairing import decode_pairing_payload
from app.runtime_config import RuntimeConfig


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
    monkeypatch.setenv("VOCAPHONE_PUBLIC_URL", "http://192.168.1.75:8765")
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
async def test_pairing_defaults_to_bootstrap_token_dropdown(
    client: httpx.AsyncClient,
    authorization: dict[str, str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("VOCAPHONE_PUBLIC_URL", "http://192.168.1.75:8765")
    partial = await client.get("/ui/partials/pairing", headers=authorization)
    assert partial.status_code == 200
    assert '<option value="bootstrap" selected>Bootstrap token</option>' in partial.text
    assert "Or pair a new device with its own token" in partial.text


@pytest.mark.asyncio
async def test_pairing_can_select_a_device_token_for_the_qr(
    client: httpx.AsyncClient,
    authorization: dict[str, str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("VOCAPHONE_PUBLIC_URL", "http://192.168.1.75:8765")
    created = await client.post(
        "/v1/admin/tokens", headers=authorization, json={"label": "Pixel 6a"}
    )
    assert created.status_code == 200
    device = created.json()

    api = await client.get(
        "/v1/admin/pairing",
        headers=authorization,
        params={"url": "http://192.168.1.75:8765", "token_id": device["id"]},
    )
    assert api.status_code == 200
    decoded = decode_pairing_payload(api.json()["payload"])
    assert decoded.token == device["token"]
    assert decoded.token != TOKEN

    partial = await client.get(
        "/ui/partials/pairing",
        headers=authorization,
        params={"token_id": device["id"]},
    )
    assert partial.status_code == 200
    assert f'<option value="{device["id"]}" selected>Pixel 6a</option>' in partial.text
    assert "no longer available" not in partial.text


@pytest.mark.asyncio
async def test_pairing_falls_back_to_bootstrap_for_revoked_or_unknown_token(
    client: httpx.AsyncClient,
    authorization: dict[str, str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("VOCAPHONE_PUBLIC_URL", "http://192.168.1.75:8765")
    created = await client.post(
        "/v1/admin/tokens", headers=authorization, json={"label": "Old phone"}
    )
    device_id = created.json()["id"]
    await client.delete(f"/v1/admin/tokens/{device_id}", headers=authorization)

    for missing_id in (device_id, "never-existed"):
        api = await client.get(
            "/v1/admin/pairing",
            headers=authorization,
            params={"url": "http://192.168.1.75:8765", "token_id": missing_id},
        )
        assert decode_pairing_payload(api.json()["payload"]).token == TOKEN

        partial = await client.get(
            "/ui/partials/pairing",
            headers=authorization,
            params={"token_id": missing_id},
        )
        assert "no longer exists" in partial.text
        assert '<option value="bootstrap" selected>Bootstrap token</option>' in partial.text


@pytest.mark.asyncio
async def test_pairing_offers_to_rotate_a_stale_device_token(
    settings: Settings,
    fake_engine: FakeEngine,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A token created before the gateway last restarted has no cached plaintext.

    It should still appear in the dropdown (marked for rotation) instead of
    silently vanishing, and rotating it should make it selectable again.
    """
    monkeypatch.setenv("VOCAPHONE_PUBLIC_URL", "http://192.168.1.75:8765")
    auth = {"Authorization": f"Bearer {TOKEN}"}

    first_app = create_app(settings, engine=fake_engine, normalizer=FakeNormalizer())
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=first_app), base_url="http://test"
    ) as first_client:
        created = await first_client.post(
            "/v1/admin/tokens", headers=auth, json={"label": "Kanishk's Iphone"}
        )
        device_id = created.json()["id"]

    # A fresh app over the same data directory simulates a restart: the token
    # still exists on disk, but no process has its plaintext cached anymore.
    second_app = create_app(settings, engine=fake_engine, normalizer=FakeNormalizer())
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=second_app), base_url="http://test"
    ) as second_client:
        partial = await second_client.get(
            "/ui/partials/pairing", headers=auth, params={"token_id": device_id}
        )
        assert "Kanishk&#x27;s Iphone (paired; no live QR)" in partial.text
        assert "is still paired and working normally" in partial.text
        assert f'hx-post="/ui/partials/pairing/tokens/{device_id}/rotate"' in partial.text
        assert '<option value="bootstrap" selected>Bootstrap token</option>' in partial.text

        rotated = await second_client.post(
            f"/ui/partials/pairing/tokens/{device_id}/rotate",
            headers=auth,
            data={"url": "http://192.168.1.75:8765"},
        )
        assert rotated.status_code == 200
        assert (
            f'<option value="{device_id}" selected>Kanishk&#x27;s Iphone</option>' in rotated.text
        )
        assert "still paired and working normally" not in rotated.text


@pytest.mark.asyncio
async def test_creating_a_pairing_token_shows_its_own_qr(
    client: httpx.AsyncClient,
    authorization: dict[str, str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("VOCAPHONE_PUBLIC_URL", "http://192.168.1.75:8765")
    response = await client.post(
        "/ui/partials/pairing/tokens",
        headers=authorization,
        data={"label": "Work iPad", "url": "http://192.168.1.75:8765"},
    )
    assert response.status_code == 200
    assert '<option value="bootstrap">Bootstrap token</option>' in response.text
    assert "selected>Work iPad</option>" in response.text

    tokens = await client.get("/v1/admin/tokens", headers=authorization)
    labels = {entry["label"] for entry in tokens.json()}
    assert "Work iPad" in labels


@pytest.mark.asyncio
async def test_switching_networks_forgets_the_old_lan_address(tmp_path: Path) -> None:
    """Reproduces the reported bug: an old Wi-Fi's LAN IP lingered forever
    alongside the new one instead of being superseded by fresh discovery."""
    settings = Settings(
        token=TOKEN,
        data_dir=tmp_path,
        whisper_binary=tmp_path / "whisper-cli",
        whisper_model=tmp_path / "model.bin",
        config_path=tmp_path / "config.json",
    )
    old_address = "http://192.168.1.20:8765"
    hostname_address = "https://homelabone.tail1234.ts.net:8765"
    runtime_config = RuntimeConfig(
        pairing_url=old_address,
        pairing_urls=[old_address, hostname_address],
    )
    app = create_app(
        settings,
        model_manager=ModelManager(tmp_path / "models"),
        runtime_config=runtime_config,
    )

    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://test"
    ) as client:
        auth = {"Authorization": f"Bearer {TOKEN}"}
        partial = await client.get("/ui/partials/pairing", headers=auth)
        assert partial.status_code == 200
        assert f'value="{old_address}"' not in partial.text
        assert f'value="{hostname_address}"' in partial.text

    # The stale ambient LAN IP is gone; the deliberately-typed hostname stayed.
    assert old_address not in runtime_config.pairing_urls
    assert hostname_address in runtime_config.pairing_urls
    assert runtime_config.pairing_url != old_address


@pytest.mark.asyncio
async def test_pairing_accepts_bare_tailscale_address(
    client: httpx.AsyncClient,
    authorization: dict[str, str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("VOCAPHONE_PUBLIC_URL", "http://192.168.1.75:8765")

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
