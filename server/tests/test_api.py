from __future__ import annotations

from uuid import uuid4

import httpx
from conftest import TOKEN


async def test_health_is_public_and_separates_engine_readiness(
    client: httpx.AsyncClient,
) -> None:
    response = await client.get("/health")
    assert response.status_code == 200
    assert response.json() == {
        "status": "ok",
        "engine_ready": True,
        "engine": "fake-local-model",
    }


async def test_private_endpoints_require_bearer_token(client: httpx.AsyncClient) -> None:
    response = await client.get("/v1/models")
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "unauthorized"
    assert TOKEN not in response.text


async def test_complete_flow_is_idempotent_and_deletes_successful_audio(
    client: httpx.AsyncClient,
    authorization: dict[str, str],
    audio_bytes: bytes,
) -> None:
    session_id = uuid4()
    payload = {
        "client_session_id": str(session_id),
        "language": "auto",
        "style": "raw",
    }
    created = await client.post("/v1/sessions", headers=authorization, json=payload)
    repeated = await client.post("/v1/sessions", headers=authorization, json=payload)
    assert created.status_code == 200
    assert repeated.json()["job_id"] == created.json()["job_id"]

    uploaded = await client.put(
        f"/v1/sessions/{session_id}/audio",
        headers={**authorization, "Content-Type": "audio/wav"},
        content=audio_bytes,
    )
    assert uploaded.status_code == 200
    assert uploaded.json()["state"] == "uploaded"

    finished = await client.post(f"/v1/sessions/{session_id}/finish", headers=authorization)
    finished_again = await client.post(f"/v1/sessions/{session_id}/finish", headers=authorization)
    assert finished.status_code == 200
    assert finished.json()["transcript"] == "hello from the local model"
    assert finished_again.json()["transcript"] == finished.json()["transcript"]
    assert finished_again.json()["job_id"] == finished.json()["job_id"]


async def test_session_accepts_writing_styles_and_rejects_unknown_values(
    client: httpx.AsyncClient,
    authorization: dict[str, str],
) -> None:
    for style in ("formal", "casual", "very_casual", "excited"):
        response = await client.post(
            "/v1/sessions",
            headers=authorization,
            json={"client_session_id": str(uuid4()), "style": style},
        )
        assert response.status_code == 200
        assert response.json()["style"] == style

    invalid = await client.post(
        "/v1/sessions",
        headers=authorization,
        json={"client_session_id": str(uuid4()), "style": "pirate"},
    )
    assert invalid.status_code == 422


async def test_writing_style_is_applied_to_the_local_transcript(
    client: httpx.AsyncClient,
    authorization: dict[str, str],
    audio_bytes: bytes,
) -> None:
    session_id = uuid4()
    await client.post(
        "/v1/sessions",
        headers=authorization,
        json={"client_session_id": str(session_id), "style": "formal"},
    )
    await client.put(
        f"/v1/sessions/{session_id}/audio",
        headers={**authorization, "Content-Type": "audio/wav"},
        content=audio_bytes,
    )

    finished = await client.post(f"/v1/sessions/{session_id}/finish", headers=authorization)

    assert finished.status_code == 200
    assert finished.json()["transcript"] == "Hello from the local model."


async def test_upload_rejects_unsupported_empty_and_oversized_audio(
    client: httpx.AsyncClient,
    authorization: dict[str, str],
) -> None:
    async def create() -> str:
        session_id = str(uuid4())
        await client.post(
            "/v1/sessions",
            headers=authorization,
            json={"client_session_id": session_id},
        )
        return session_id

    unsupported = await client.put(
        f"/v1/sessions/{await create()}/audio",
        headers={**authorization, "Content-Type": "text/plain"},
        content=b"x" * 200,
    )
    empty = await client.put(
        f"/v1/sessions/{await create()}/audio",
        headers={**authorization, "Content-Type": "audio/wav"},
        content=b"x",
    )
    oversized = await client.put(
        f"/v1/sessions/{await create()}/audio",
        headers={**authorization, "Content-Type": "audio/wav"},
        content=b"x" * 20_001,
    )
    assert unsupported.status_code == 415
    assert empty.status_code == 422
    assert oversized.status_code == 413


async def test_delete_is_idempotent(
    client: httpx.AsyncClient,
    authorization: dict[str, str],
) -> None:
    session_id = uuid4()
    await client.post(
        "/v1/sessions",
        headers=authorization,
        json={"client_session_id": str(session_id)},
    )
    first = await client.delete(f"/v1/sessions/{session_id}", headers=authorization)
    second = await client.delete(f"/v1/sessions/{session_id}", headers=authorization)
    assert first.status_code == 200
    assert first.json() == {"deleted": True}
    assert second.status_code == 404
    assert second.json() == {"deleted": False}
