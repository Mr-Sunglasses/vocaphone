from __future__ import annotations

from pathlib import Path

from app.models.base import TranscriptionOptions
from app.models.handy import HandyEngine


async def test_handy_adapter_uses_downloaded_model_and_parses_json(
    tmp_path: Path,
) -> None:
    model = "owner/repository/model.gguf"
    binary = tmp_path / "handy"
    binary.write_text(
        "#!/bin/sh\nprintf '%s\\n' '{\"text\":\"private local result\"}'\n",
        encoding="utf-8",
    )
    binary.chmod(0o700)
    model_path = (
        tmp_path / "cache" / "models--owner--repository" / "snapshots" / "revision" / "model.gguf"
    )
    model_path.parent.mkdir(parents=True)
    model_path.write_bytes(b"model")
    audio = tmp_path / "audio.wav"
    audio.write_bytes(b"audio")

    engine = HandyEngine(binary, model, huggingface_cache=tmp_path / "cache")
    health = await engine.health()
    transcript = await engine.transcribe(
        audio,
        TranscriptionOptions(language="auto", style="raw"),
    )

    assert health.ready is True
    assert health.name == f"handy:{model}"
    assert transcript == "private local result"


async def test_handy_health_is_false_when_model_is_not_downloaded(
    tmp_path: Path,
) -> None:
    binary = tmp_path / "handy"
    binary.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    binary.chmod(0o700)
    engine = HandyEngine(
        binary,
        "owner/repository/missing.gguf",
        huggingface_cache=tmp_path / "cache",
    )
    assert (await engine.health()).ready is False


async def test_handy_retries_empty_primary_result_with_downloaded_fallback(
    tmp_path: Path,
) -> None:
    primary = "owner/primary/primary.gguf"
    fallback = "owner/fallback/fallback.gguf"
    binary = tmp_path / "handy"
    binary.write_text(
        "#!/bin/sh\n"
        'case "$*" in\n'
        "  *primary.gguf*) printf '%s\\n' '{\"text\":\"\"}' ;;\n"
        "  *) printf '%s\\n' '{\"text\":\"fallback result\"}' ;;\n"
        "esac\n",
        encoding="utf-8",
    )
    binary.chmod(0o700)
    for model in (primary, fallback):
        owner, repository, filename = model.split("/")
        model_path = (
            tmp_path
            / "cache"
            / f"models--{owner}--{repository}"
            / "snapshots"
            / "revision"
            / filename
        )
        model_path.parent.mkdir(parents=True)
        model_path.write_bytes(b"model")
    audio = tmp_path / "audio.wav"
    audio.write_bytes(b"audio")

    engine = HandyEngine(
        binary,
        primary,
        fallback_model=fallback,
        huggingface_cache=tmp_path / "cache",
    )

    transcript = await engine.transcribe(
        audio,
        TranscriptionOptions(language="auto", style="raw"),
    )

    assert transcript == "fallback result"
