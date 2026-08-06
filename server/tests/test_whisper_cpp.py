from __future__ import annotations

from pathlib import Path

import pytest

from app.errors import EngineUnavailableError, TranscriptionProcessError
from app.models.base import TranscriptionOptions
from app.models.whisper_cpp import WhisperCppEngine


def _write_binary(path: Path, script: str) -> None:
    path.write_text(script, encoding="utf-8")
    path.chmod(0o700)


async def test_health_requires_both_the_binary_and_the_model(tmp_path: Path) -> None:
    binary = tmp_path / "whisper-cli"
    model = tmp_path / "model.bin"

    engine = WhisperCppEngine(binary, model)
    assert (await engine.health()).ready is False

    _write_binary(binary, "#!/bin/sh\nexit 0\n")
    assert (await engine.health()).ready is False

    model.write_bytes(b"model")
    health = await engine.health()
    assert health.ready is True
    assert health.name == f"whisper.cpp:{model.name}"


async def test_transcribe_writes_the_output_stem_and_returns_its_contents(
    tmp_path: Path,
) -> None:
    binary = tmp_path / "whisper-cli"
    _write_binary(
        binary,
        """#!/bin/sh
printf '%s\\n' "$@" > "$0.args"
of=""
lang=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -of) of="$2"; shift 2 ;;
    -l) lang="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s' "private local result" > "$of.txt"
""",
    )
    model = tmp_path / "model.bin"
    model.write_bytes(b"model")
    audio = tmp_path / "audio.wav"
    audio.write_bytes(b"audio")

    engine = WhisperCppEngine(binary, model)
    transcript = await engine.transcribe(audio, TranscriptionOptions("en", "raw"))

    assert transcript == "private local result"
    arguments = (tmp_path / "whisper-cli.args").read_text(encoding="utf-8").splitlines()
    assert arguments[arguments.index("-l") + 1] == "en"
    assert arguments[arguments.index("-f") + 1] == str(audio)


async def test_transcribe_omits_the_language_flag_when_auto(tmp_path: Path) -> None:
    binary = tmp_path / "whisper-cli"
    _write_binary(
        binary,
        """#!/bin/sh
printf '%s\\n' "$@" > "$0.args"
of=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -of) of="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s' "auto detected" > "$of.txt"
""",
    )
    model = tmp_path / "model.bin"
    model.write_bytes(b"model")
    audio = tmp_path / "audio.wav"
    audio.write_bytes(b"audio")

    engine = WhisperCppEngine(binary, model)
    transcript = await engine.transcribe(audio, TranscriptionOptions("auto", "raw"))

    assert transcript == "auto detected"
    arguments = (tmp_path / "whisper-cli.args").read_text(encoding="utf-8").splitlines()
    assert "-l" not in arguments


async def test_transcribe_raises_when_the_engine_is_unavailable(tmp_path: Path) -> None:
    engine = WhisperCppEngine(tmp_path / "missing-cli", tmp_path / "missing-model.bin")

    with pytest.raises(EngineUnavailableError):
        await engine.transcribe(tmp_path / "audio.wav", TranscriptionOptions("auto", "raw"))


async def test_transcribe_raises_on_a_nonzero_exit_code(tmp_path: Path) -> None:
    binary = tmp_path / "whisper-cli"
    _write_binary(binary, "#!/bin/sh\necho 'boom' 1>&2\nexit 1\n")
    model = tmp_path / "model.bin"
    model.write_bytes(b"model")
    audio = tmp_path / "audio.wav"
    audio.write_bytes(b"audio")

    engine = WhisperCppEngine(binary, model)

    with pytest.raises(TranscriptionProcessError, match="boom"):
        await engine.transcribe(audio, TranscriptionOptions("auto", "raw"))


async def test_transcribe_raises_when_the_transcript_is_empty(tmp_path: Path) -> None:
    binary = tmp_path / "whisper-cli"
    _write_binary(
        binary,
        """#!/bin/sh
of=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -of) of="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '' > "$of.txt"
""",
    )
    model = tmp_path / "model.bin"
    model.write_bytes(b"model")
    audio = tmp_path / "audio.wav"
    audio.write_bytes(b"audio")

    engine = WhisperCppEngine(binary, model)

    with pytest.raises(TranscriptionProcessError, match="empty"):
        await engine.transcribe(audio, TranscriptionOptions("auto", "raw"))


async def test_warmup_prefetches_the_model_when_ready(tmp_path: Path) -> None:
    binary = tmp_path / "whisper-cli"
    _write_binary(binary, "#!/bin/sh\nexit 0\n")
    model = tmp_path / "model.bin"
    model.write_bytes(b"x" * 1024)

    engine = WhisperCppEngine(binary, model)
    advised = await engine.warmup()

    assert advised > 0


async def test_warmup_is_a_noop_when_not_ready(tmp_path: Path) -> None:
    engine = WhisperCppEngine(tmp_path / "missing-cli", tmp_path / "missing-model.bin")

    assert await engine.warmup() == 0
