from __future__ import annotations

import asyncio
import dataclasses
from collections.abc import AsyncIterator
from pathlib import Path

import httpx
import pytest
from conftest import TOKEN, FakeNormalizer

from app.catalog import CatalogModel
from app.config import Settings
from app.main import create_app
from app.model_manager import ModelManager
from app.runtime_config import RuntimeConfig

TINY = CatalogModel(
    id="whisper.cpp:ggml-tiny.bin",
    engine="whisper.cpp",
    key="ggml-tiny.bin",
    label="Test Tiny",
    size_bytes=11,
    languages="Multilingual",
    quality="Fastest",
    minimum_ram_gb=4,
)


@pytest.fixture
def admin_settings(tmp_path: Path) -> Settings:
    return Settings(
        token=TOKEN,
        data_dir=tmp_path,
        whisper_binary=tmp_path / "whisper-cli",
        whisper_model=tmp_path / "model.bin",
        handy_binary=tmp_path / "no-handy",
        models_dir=tmp_path / "models",
        config_path=tmp_path / "config.json",
    )


@pytest.fixture
def admin_manager(tmp_path: Path) -> ModelManager:
    source = tmp_path / "source.bin"
    source.write_bytes(b"hello model")
    catalog = (dataclasses.replace(TINY, download_url=source.as_uri()),)
    return ModelManager(tmp_path / "models", catalog=catalog)


@pytest.fixture
async def admin_client(
    admin_settings: Settings, admin_manager: ModelManager
) -> AsyncIterator[httpx.AsyncClient]:
    app = create_app(
        admin_settings,
        model_manager=admin_manager,
        runtime_config=RuntimeConfig(),
        normalizer=FakeNormalizer(),
    )
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app),
        base_url="http://test",
    ) as test_client:
        yield test_client


@pytest.fixture
def auth() -> dict[str, str]:
    return {"Authorization": f"Bearer {TOKEN}"}


async def test_admin_endpoints_require_token(admin_client: httpx.AsyncClient) -> None:
    for path in (
        "/v1/admin/status",
        "/v1/admin/models",
        "/v1/admin/config",
        "/ui/partials/overview",
        "/ui/partials/models",
        "/ui/partials/settings",
    ):
        response = await admin_client.get(path)
        assert response.status_code == 401, path


async def test_status_reports_system_and_setup(
    admin_client: httpx.AsyncClient, auth: dict[str, str]
) -> None:
    response = await admin_client.get("/v1/admin/status", headers=auth)
    assert response.status_code == 200
    payload = response.json()
    assert payload["engine"]["id"] == "auto"
    assert payload["system"]["arch"]
    assert {dependency["name"] for dependency in payload["dependencies"]} == {
        "FFmpeg",
        "whisper.cpp CLI",
        "WhisperKit CLI",
        "Handy app",
    }
    assert payload["setup"]["token_configured"] is True
    assert payload["setup"]["model_installed"] is False
    assert payload["bind_host"] == "0.0.0.0"
    assert payload["port"] == 8765
    assert payload["metrics"] == {
        "uptime_seconds": payload["metrics"]["uptime_seconds"],
        "queue_depth": 0,
        "active_transcriptions": 0,
        "concurrency_limit": 1,
        "successful_transcriptions": 0,
        "failed_transcriptions": 0,
        "rejected_transcriptions": 0,
        "average_latency_ms": None,
        "last_latency_ms": None,
    }
    assert payload["readiness"]["warmup_state"] == "pending"


async def test_models_list_contains_catalog(
    admin_client: httpx.AsyncClient, auth: dict[str, str]
) -> None:
    response = await admin_client.get("/v1/admin/models", headers=auth)
    assert response.status_code == 200
    entries = {entry["id"]: entry for entry in response.json()}
    assert "whisper.cpp:ggml-tiny.bin" in entries
    assert entries["whisper.cpp:ggml-tiny.bin"]["state"] == "not_installed"
    assert entries["whisper.cpp:ggml-tiny.bin"]["family"] == "Whisper"
    assert entries["whisper.cpp:ggml-tiny.bin"]["description"]


async def test_download_select_and_delete_flow(
    admin_client: httpx.AsyncClient,
    auth: dict[str, str],
    admin_settings: Settings,
) -> None:
    model_id = "whisper.cpp:ggml-tiny.bin"

    missing = await admin_client.post(f"/v1/admin/models/{model_id}/select", headers=auth)
    assert missing.status_code == 404

    started = await admin_client.post(f"/v1/admin/models/{model_id}/download", headers=auth)
    assert started.status_code == 200

    duplicate = await admin_client.post(f"/v1/admin/models/{model_id}/download", headers=auth)
    assert duplicate.status_code == 409

    for _ in range(200):
        entries = {
            entry["id"]: entry
            for entry in (await admin_client.get("/v1/admin/models", headers=auth)).json()
        }
        if entries[model_id]["state"] == "installed":
            break
        await asyncio.sleep(0.02)
    assert entries[model_id]["state"] == "installed"

    selected = await admin_client.post(f"/v1/admin/models/{model_id}/select", headers=auth)
    assert selected.status_code == 200
    assert selected.json()["engine"]["id"] == "whisper.cpp"

    saved = RuntimeConfig.load(admin_settings.config_path)
    assert saved.engine == "whisper.cpp"
    assert saved.whisper_model and saved.whisper_model.endswith("ggml-tiny.bin")

    entries = {
        entry["id"]: entry
        for entry in (await admin_client.get("/v1/admin/models", headers=auth)).json()
    }
    assert entries[model_id]["active"] is True

    deleted = await admin_client.delete(f"/v1/admin/models/{model_id}", headers=auth)
    assert deleted.status_code == 200
    saved = RuntimeConfig.load(admin_settings.config_path)
    assert saved.whisper_model is None


async def test_unknown_model_download_404(
    admin_client: httpx.AsyncClient, auth: dict[str, str]
) -> None:
    response = await admin_client.post(
        "/v1/admin/models/whisper.cpp:missing.bin/download", headers=auth
    )
    assert response.status_code == 404


async def test_config_update_persists_engine(
    admin_client: httpx.AsyncClient, auth: dict[str, str], admin_settings: Settings
) -> None:
    invalid = await admin_client.put("/v1/admin/config", headers=auth, json={"engine": "cloud"})
    assert invalid.status_code == 422

    updated = await admin_client.put(
        "/v1/admin/config", headers=auth, json={"engine": "whisperkit"}
    )
    assert updated.status_code == 200
    assert RuntimeConfig.load(admin_settings.config_path).engine == "whisperkit"


async def test_custom_download_rejects_bad_url(
    admin_client: httpx.AsyncClient, auth: dict[str, str]
) -> None:
    response = await admin_client.post(
        "/v1/admin/models/custom",
        headers=auth,
        json={"url": "https://example.com/not-a-model.txt"},
    )
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "invalid_model_url"


async def test_partials_render_html(admin_client: httpx.AsyncClient, auth: dict[str, str]) -> None:
    overview = await admin_client.get("/ui/partials/overview", headers=auth)
    assert overview.status_code == 200
    assert "Setup checklist" in overview.text
    assert "Live operations" in overview.text
    assert 'hx-get="/ui/partials/operations"' in overview.text
    assert "0.0.0.0:8765" in overview.text
    assert "http://127.0.0.1:8765/" in overview.text
    assert "Available on every network interface" in overview.text

    models = await admin_client.get("/ui/partials/models", headers=auth)
    assert models.status_code == 200
    assert "Test Tiny" in models.text
    assert 'class="model-card"' in models.text
    assert 'hx-trigger="every 1500ms"' not in models.text
    assert 'hx-post="/ui/partials/models/whisper.cpp%3Aggml-tiny.bin/download"' in models.text

    settings = await admin_client.get("/ui/partials/settings", headers=auth)
    assert settings.status_code == 200
    assert "Speech engine" in settings.text
    assert "All-interface listener" in settings.text

    operations = await admin_client.get("/ui/partials/operations", headers=auth)
    assert operations.status_code == 200
    assert "0 queued" in operations.text
    assert "Average latency" in operations.text

    pill = await admin_client.get("/ui/partials/engine-pill", headers=auth)
    assert pill.status_code == 200
    assert "engine-pill" in pill.text


async def test_webui_shell_is_public(admin_client: httpx.AsyncClient) -> None:
    response = await admin_client.get("/")
    assert response.status_code == 200
    assert "htmx.min.js" in response.text
    assert response.headers["cache-control"] == "no-store"
    assert response.headers["x-frame-options"] == "DENY"
    assert response.headers["x-content-type-options"] == "nosniff"
    assert response.headers["referrer-policy"] == "no-referrer"
    assert response.headers["permissions-policy"] == "microphone=(self)"
    assert "frame-ancestors 'none'" in response.headers["content-security-policy"]


async def test_private_responses_are_not_cached(
    admin_client: httpx.AsyncClient, auth: dict[str, str]
) -> None:
    response = await admin_client.get("/v1/admin/status", headers=auth)
    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"


async def test_recorder_ui_shows_limit_and_copy_action(
    admin_client: httpx.AsyncClient, auth: dict[str, str]
) -> None:
    response = await admin_client.get("/ui/partials/test", headers=auth)
    assert response.status_code == 200
    assert 'data-maximum-seconds="120"' in response.text
    assert 'id="record-timer"' in response.text
    assert 'id="copy-transcript"' in response.text


async def test_test_transcription_endpoint(
    client: httpx.AsyncClient,
    authorization: dict[str, str],
    audio_bytes: bytes,
) -> None:
    response = await client.post(
        "/v1/admin/test-transcription?language=en",
        headers={**authorization, "Content-Type": "audio/wav"},
        content=audio_bytes,
    )
    assert response.status_code == 200
    payload = response.json()
    assert payload["transcript"] == "hello from the local model"
    assert payload["engine"] == "fake-local-model"
    assert payload["duration_ms"] >= 0

    status = await client.get("/v1/admin/status", headers=authorization)
    metrics = status.json()["metrics"]
    assert metrics["successful_transcriptions"] == 1
    assert metrics["failed_transcriptions"] == 0
    assert metrics["queue_depth"] == 0
    assert metrics["active_transcriptions"] == 0
    assert metrics["last_latency_ms"] == payload["duration_ms"]


async def test_test_transcription_rejects_unsupported_type(
    client: httpx.AsyncClient, authorization: dict[str, str]
) -> None:
    response = await client.post(
        "/v1/admin/test-transcription",
        headers={**authorization, "Content-Type": "text/plain"},
        content=b"x" * 200,
    )
    assert response.status_code == 415
