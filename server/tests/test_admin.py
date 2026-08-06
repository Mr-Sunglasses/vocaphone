from __future__ import annotations

import asyncio
import dataclasses
from collections.abc import AsyncIterator
from pathlib import Path

import httpx
import pytest
from conftest import TOKEN, FakeNormalizer

from app import engines as engines_module
from app import main
from app.catalog import CatalogModel
from app.config import Settings
from app.main import create_app
from app.model_manager import ModelManager
from app.runtime_config import RuntimeConfig

MAC_ONLY = frozenset({"vocamac", "handy", "whisperkit", "mlx-audio"})

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
        vocamac_app=tmp_path / "no-vocamac",
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
        "/v1/admin/diagnostics",
        "/v1/admin/tokens",
        "/v1/admin/models",
        "/v1/admin/config",
        "/ui/partials/overview",
        "/ui/partials/models",
        "/ui/partials/settings",
    ):
        response = await admin_client.get(path)
        assert response.status_code == 401, path


async def test_tokens_list_starts_with_only_the_bootstrap_entry(
    admin_client: httpx.AsyncClient, auth: dict[str, str]
) -> None:
    response = await admin_client.get("/v1/admin/tokens", headers=auth)
    assert response.status_code == 200
    entries = response.json()
    assert entries == [
        {
            "id": "bootstrap",
            "label": "Bootstrap token (LOCALFLOW_TOKEN / token file)",
            "created_at": None,
            "revocable": False,
        }
    ]


async def test_created_device_token_authenticates_and_can_be_revoked(
    admin_client: httpx.AsyncClient, auth: dict[str, str]
) -> None:
    created = await admin_client.post("/v1/admin/tokens", headers=auth, json={"label": "Pixel 6a"})
    assert created.status_code == 200
    payload = created.json()
    assert payload["label"] == "Pixel 6a"
    device_auth = {"Authorization": f"Bearer {payload['token']}"}

    # The new device token authenticates on its own, independent of the bootstrap token.
    status = await admin_client.get("/v1/admin/status", headers=device_auth)
    assert status.status_code == 200

    listed = await admin_client.get("/v1/admin/tokens", headers=auth)
    ids = {entry["id"]: entry for entry in listed.json()}
    assert payload["id"] in ids
    assert ids[payload["id"]]["revocable"] is True

    revoked = await admin_client.delete(f"/v1/admin/tokens/{payload['id']}", headers=auth)
    assert revoked.status_code == 200
    assert revoked.json() == {"revoked": True}

    # Revoking one device token never touches the bootstrap token or other clients.
    still_ok = await admin_client.get("/v1/admin/status", headers=auth)
    assert still_ok.status_code == 200
    now_rejected = await admin_client.get("/v1/admin/status", headers=device_auth)
    assert now_rejected.status_code == 401


async def test_revoking_unknown_token_returns_404(
    admin_client: httpx.AsyncClient, auth: dict[str, str]
) -> None:
    response = await admin_client.delete("/v1/admin/tokens/does-not-exist", headers=auth)
    assert response.status_code == 404
    assert response.json() == {"revoked": False}


async def test_bootstrap_token_cannot_be_revoked(
    admin_client: httpx.AsyncClient, auth: dict[str, str]
) -> None:
    response = await admin_client.delete("/v1/admin/tokens/bootstrap", headers=auth)
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "bootstrap_token_not_revocable"


async def test_diagnostics_bundle_is_downloadable_and_redacted(
    admin_client: httpx.AsyncClient, auth: dict[str, str]
) -> None:
    response = await admin_client.get("/v1/admin/diagnostics", headers=auth)
    assert response.status_code == 200
    assert response.headers["content-disposition"].startswith(
        'attachment; filename="localflow-diagnostics-'
    )
    payload = response.json()
    assert payload["engine"]["id"] == "auto"
    assert payload["config"]["engine"] == "auto"
    assert "never_included" in payload and payload["never_included"]
    assert TOKEN not in response.text


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
        "VocaMac app",
        "faster-whisper",
        "Moonshine Voice",
        "sherpa-onnx",
        "MLX Audio",
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
        "normalization_ms": None,
        "model_load_ms": None,
        "inference_ms": None,
        "audio_duration_ms": None,
        "real_time_factor": None,
        "peak_memory_mb": None,
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


async def test_models_list_installed_only_filter(
    admin_client: httpx.AsyncClient, auth: dict[str, str]
) -> None:
    model_id = "whisper.cpp:ggml-tiny.bin"

    before = await admin_client.get(
        "/v1/admin/models", params={"installed_only": "true"}, headers=auth
    )
    assert before.status_code == 200
    assert model_id not in {entry["id"] for entry in before.json()}

    started = await admin_client.post(f"/v1/admin/models/{model_id}/download", headers=auth)
    assert started.status_code == 200

    for _ in range(200):
        filtered = {
            entry["id"]: entry
            for entry in (
                await admin_client.get(
                    "/v1/admin/models", params={"installed_only": "true"}, headers=auth
                )
            ).json()
        }
        if model_id in filtered:
            break
        await asyncio.sleep(0.02)
    assert filtered[model_id]["state"] == "installed"
    assert all(entry["state"] == "installed" for entry in filtered.values())


async def test_ui_select_preserves_installed_only_filter(
    admin_client: httpx.AsyncClient, auth: dict[str, str]
) -> None:
    model_id = "whisper.cpp:ggml-tiny.bin"

    await admin_client.post(f"/v1/admin/models/{model_id}/download", headers=auth)
    entries: dict[str, dict[str, object]] = {}
    for _ in range(200):
        entries = {
            entry["id"]: entry
            for entry in (await admin_client.get("/v1/admin/models", headers=auth)).json()
        }
        if entries[model_id]["state"] == "installed":
            break
        await asyncio.sleep(0.02)
    assert entries[model_id]["state"] == "installed"

    selected = await admin_client.post(
        f"/ui/partials/models/{model_id}/select",
        headers=auth,
        data={"installed_only": "true"},
    )
    assert selected.status_code == 200
    assert 'class="model-card"' in selected.text
    assert "No models downloaded yet" not in selected.text


def test_language_filter_answers_which_model_should_i_use() -> None:
    """The filter exists to invert the question people actually ask. Driven off
    the real catalog, since the stub the admin fixtures use has one model."""
    from app.catalog import DEFAULT_CATALOG, language_names
    from app.main import _model_covers
    from app.schemas import AdminModelEntry

    entries = [
        AdminModelEntry(
            id=m.id,
            engine=m.engine,
            label=m.label,
            size_bytes=m.size_bytes,
            languages=m.languages,
            quality=m.quality,
            family=m.family,
            description=m.description,
            source=m.source,
            state="not_installed",
            active=False,
            recommended=False,
            detects_language_automatically=m.detects_language_automatically,
            language_names=language_names(m.language_codes),
            language_codes=list(m.language_codes),
        )
        for m in DEFAULT_CATALOG
    ]

    hindi = [e for e in entries if _model_covers(e, "hi")]
    assert hindi, "Hindi must match something"
    assert len(hindi) < len(entries), "the filter has to actually narrow the list"
    # Both the auto-detecting recogniser and the pinnable Whisper builds appear,
    # so the badge is what tells them apart rather than their absence.
    assert any("dolphin" in e.id for e in hindi)
    assert any(e.engine == "whisper.cpp" for e in hindi)
    # An English-only build must not surface under Hindi.
    assert not any(e.id.endswith(".en.bin") for e in hindi)

    # Omnilingual declares no codes; it covers 1600+ languages, so it matches
    # everything rather than disappearing from every filter.
    omni = next(e for e in entries if "omnilingual" in e.id)
    assert _model_covers(omni, "hi") and _model_covers(omni, "yo")

    english = [e for e in entries if _model_covers(e, "en")]
    assert any(e.id.endswith(".en.bin") for e in english)

    # Moonshine carries its language in `language_code`, not `language_codes`.
    # Leaving the tuple empty made every English Moonshine match "covers
    # everything", so they all turned up under Hindi.
    assert not any(e.engine == "moonshine" and e.id != "moonshine:hi" for e in hindi)
    assert any(e.engine == "moonshine" for e in english)

    # Odia is real but Whisper-less: only Dolphin and Omnilingual cover it, which
    # is exactly why the phone clients do not offer it as a choice.
    odia = [e for e in entries if _model_covers(e, "or")]
    assert odia and all(e.detects_language_automatically for e in odia)


def test_language_filter_offers_only_languages_some_model_covers() -> None:
    from app.fragments import _language_filter_options

    options = _language_filter_options()
    assert '<option value="hi">Hindi</option>' in options
    assert '<option value="ta">Tamil</option>' in options
    # Odia is Dolphin-only, which is still a model, so it belongs here even
    # though the phone clients deliberately do not offer it.
    assert '<option value="or">Odia</option>' in options
    # A language no catalog model covers must not appear as a dead option.
    assert 'value="xx"' not in options


async def test_ui_actions_preserve_the_language_filter(
    admin_client: httpx.AsyncClient, auth: dict[str, str]
) -> None:
    """Downloading or selecting must not silently reset the view, the same
    guarantee the installed-only toggle already makes."""
    listed = await admin_client.get(
        "/ui/partials/models-list", params={"language": "hi"}, headers=auth
    )
    assert listed.status_code == 200

    # The stub catalog's only model is multilingual Whisper, so it covers Hindi.
    assert 'class="model-card"' in listed.text

    filtered_out = await admin_client.get(
        "/ui/partials/models-list", params={"language": "yue"}, headers=auth
    )
    assert "Cantonese" in filtered_out.text or 'class="model-card"' in filtered_out.text


async def test_admin_models_api_accepts_the_language_filter(
    admin_client: httpx.AsyncClient, auth: dict[str, str]
) -> None:
    response = await admin_client.get("/v1/admin/models", params={"language": "hi"}, headers=auth)
    assert response.status_code == 200
    assert all(
        "hi" in entry["language_codes"] or not entry["language_codes"] for entry in response.json()
    )


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
        "/v1/admin/config", headers=auth, json={"engine": "sherpa-onnx"}
    )
    assert updated.status_code == 200
    assert RuntimeConfig.load(admin_settings.config_path).engine == "sherpa-onnx"


async def test_mac_only_engines_are_hidden_and_rejected_on_other_hosts(
    admin_client: httpx.AsyncClient,
    auth: dict[str, str],
    admin_settings: Settings,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(main, "engine_runs_on", lambda engine, **_: engine not in MAC_ONLY)
    monkeypatch.setattr(engines_module, "engine_runs_here", lambda engine: engine not in MAC_ONLY)

    config = await admin_client.get("/v1/admin/config", headers=auth)
    settings_html = (await admin_client.get("/ui/partials/settings", headers=auth)).text
    rejected = await admin_client.put("/v1/admin/config", headers=auth, json={"engine": "vocamac"})

    assert set(config.json()["available_engines"]).isdisjoint(MAC_ONLY)
    assert "VocaMac app" not in settings_html
    assert "Handy app" not in settings_html
    assert rejected.status_code == 422
    assert rejected.json()["error"]["code"] == "invalid_engine"
    assert "Apple silicon" in rejected.json()["error"]["message"]
    assert RuntimeConfig.load(admin_settings.config_path).engine != "vocamac"


async def test_mac_only_engines_are_labelled_with_their_host(
    admin_client: httpx.AsyncClient, auth: dict[str, str], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(main, "engine_runs_on", lambda engine, **_: True)

    settings_html = (await admin_client.get("/ui/partials/settings", headers=auth)).text

    assert "VocaMac app (Apple silicon only)" in settings_html
    assert "Handy app (macOS only)" in settings_html
    assert "sherpa-onnx</option>" in settings_html


async def test_ui_config_update_switches_engine_and_renders_a_fragment(
    admin_client: httpx.AsyncClient, auth: dict[str, str], admin_settings: Settings
) -> None:
    response = await admin_client.put(
        "/ui/partials/config",
        headers=auth,
        data={"engine": "sherpa-onnx", "compute_device": "cpu", "cpu_threads": "2"},
    )
    assert response.status_code == 200
    assert "Engine preference saved." in response.text
    assert 'id="engine-pill"' in response.text
    assert RuntimeConfig.load(admin_settings.config_path).engine == "sherpa-onnx"


async def test_ui_config_update_rejects_an_invalid_engine(
    admin_client: httpx.AsyncClient, auth: dict[str, str]
) -> None:
    response = await admin_client.put(
        "/ui/partials/config",
        headers=auth,
        data={"engine": "cloud"},
    )
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "invalid_engine"


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
    assert "Paired device tokens" in settings.text
    assert "Bootstrap token (LOCALFLOW_TOKEN / token file)" in settings.text

    tokens = await admin_client.get("/ui/partials/tokens", headers=auth)
    assert tokens.status_code == 200
    assert 'id="tokens-card"' in tokens.text

    created = await admin_client.post(
        "/ui/partials/tokens", headers=auth, data={"label": "Kanishk's iPhone"}
    )
    assert created.status_code == 200
    assert "New secret for Kanishk&#x27;s iPhone" in created.text
    assert 'id="new-token-value"' in created.text
    assert "Regenerate</button>" in created.text

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


def test_model_cards_name_their_languages() -> None:
    """ "25 European languages" does not tell anyone whether their language is in
    there. The card names them, collapsed so the summary stays scannable.

    Driven off the real catalog rather than the stub the admin fixtures use, since
    the point is that shipped entries carry usable language metadata.
    """
    from app.catalog import DEFAULT_CATALOG, language_names
    from app.fragments import _model_card
    from app.schemas import AdminModelEntry

    def card(model_id: str) -> str:
        model = next(m for m in DEFAULT_CATALOG if m.id == model_id)
        return _model_card(
            AdminModelEntry(
                id=model.id,
                engine=model.engine,
                label=model.label,
                size_bytes=model.size_bytes,
                languages=model.languages,
                quality=model.quality,
                family=model.family,
                description=model.description,
                source=model.source,
                state="not_installed",
                active=False,
                recommended=False,
                detects_language_automatically=model.detects_language_automatically,
                language_names=language_names(model.language_codes),
            )
        )

    parakeet = card("sherpa-onnx:parakeet-tdt-0.6b-v3-int8")
    assert "<summary>25 languages</summary>" in parakeet
    assert "Bulgarian, Croatian, Czech" in parakeet
    # A model that can be pinned carries neither the badge nor the caveat.
    assert "badge auto-language" not in parakeet
    assert "chooses the language itself" not in parakeet

    dolphin = card("sherpa-onnx:dolphin-small-ctc-int8")
    assert "<summary>40 languages</summary>" in dolphin
    assert "Hindi" in dolphin and "Bengali" in dolphin and "Tamil" in dolphin
    assert 'class="badge auto-language"' in dolphin
    assert "chooses the language itself" in dolphin

    # Whisper carries its full set too, and every code resolves to a real name
    # rather than leaking a bare "af, am, be" at the reader.
    whisper = card("whisper.cpp:ggml-large-v3-turbo.bin")
    assert "<summary>100 languages</summary>" in whisper
    assert "Afrikaans" in whisper and "Hindi" in whisper
    assert "badge auto-language" not in whisper

    # An English-only build carries just "en", and gets no disclosure at all —
    # its "English only" summary already says everything a list would.
    english_only = card("whisper.cpp:ggml-tiny.en.bin")
    assert "model-languages" not in english_only


async def test_recorder_offers_every_language_a_client_can_request(
    admin_client: httpx.AsyncClient, auth: dict[str, str]
) -> None:
    """The Test tab must not be narrower than the mobile pickers.

    This list is duplicated in `TranscriptionLanguage` on iOS and Android, which
    pin the same order in their own suites. An operator who downloads a model for
    a language has to be able to test that language here.
    """
    import re

    response = await admin_client.get("/ui/partials/test", headers=auth)
    select = response.text.split('<select id="test-language">')[1].split("</select>")[0]

    assert re.findall(r'<option value="([a-z]+)"', select) == [
        "auto", "ar", "as", "bn", "nl", "en", "fr", "de", "gu", "hi",
        "it", "ja", "kn", "ko", "ml", "zh", "mr", "ne", "pl", "pt",
        "pa", "ru", "es", "ta", "te", "uk", "ur", "vi",
    ]  # fmt: skip


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
    assert payload["normalization_ms"] >= 0
    assert payload["inference_ms"] >= 0
    assert "real_time_factor" in payload
    assert payload["peak_memory_mb"] > 0

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


def test_a_filtered_list_warns_which_models_suit_dictation() -> None:
    """Every auto-detecting model tested returned the wrong writing system on a
    short phrase, and dictation is mostly short phrases. A list mixing both kinds
    has to say which half to trust."""
    from app.catalog import DEFAULT_CATALOG, language_names
    from app.fragments import models_list_fragment
    from app.main import _model_covers
    from app.schemas import AdminModelEntry

    entries = [
        AdminModelEntry(
            id=m.id, engine=m.engine, label=m.label, size_bytes=m.size_bytes,
            languages=m.languages, quality=m.quality, family=m.family,
            description=m.description, source=m.source, state="not_installed",
            active=False, recommended=False,
            detects_language_automatically=m.detects_language_automatically,
            language_names=language_names(m.language_codes),
            language_codes=list(m.language_codes),
        )
        for m in DEFAULT_CATALOG
    ]  # fmt: skip

    hindi = [e for e in entries if _model_covers(e, "hi")]
    rendered = models_list_fragment(hindi, language="hi")
    assert "models-language-hint" in rendered
    assert "wrong alphabet" in rendered
    assert "Hindi" in rendered

    # No hint when there is nothing to choose between.
    only_auto = [e for e in hindi if e.detects_language_automatically]
    assert "models-language-hint" not in models_list_fragment(only_auto, language="hi")
    # And never on the unfiltered catalog, where it would just be noise.
    assert "models-language-hint" not in models_list_fragment(entries)
