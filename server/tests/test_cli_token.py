from __future__ import annotations

import json
from pathlib import Path

import pytest
from pytest import CaptureFixture, MonkeyPatch

from app import cli


def _isolate_home(monkeypatch: MonkeyPatch, tmp_path: Path) -> Path:
    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.delenv("XDG_CONFIG_HOME", raising=False)
    monkeypatch.delenv("XDG_DATA_HOME", raising=False)
    for name in list(__import__("os").environ):
        if name.startswith("LOCALFLOW_") or name.startswith("VOCAPHONE_"):
            monkeypatch.delenv(name, raising=False)
    return home


def _write_token(home: Path, secret: str = "test-token-with-at-least-thirty-two-characters") -> str:
    token_file = home / ".config" / "vocaphone" / "token"
    token_file.parent.mkdir(parents=True)
    token_file.write_text(secret + "\n", encoding="utf-8")
    return secret


def test_token_plain_prints_only_the_secret(
    tmp_path: Path, monkeypatch: MonkeyPatch, capsys: CaptureFixture[str]
) -> None:
    home = _isolate_home(monkeypatch, tmp_path)
    secret = _write_token(home)
    monkeypatch.setattr("sys.argv", ["vocaphone-token", "--plain"])

    cli.token()

    assert capsys.readouterr().out == secret + "\n"


def test_token_reads_env_override(
    tmp_path: Path, monkeypatch: MonkeyPatch, capsys: CaptureFixture[str]
) -> None:
    _isolate_home(monkeypatch, tmp_path)
    secret = "env-token-with-at-least-thirty-two-chars-ok"
    monkeypatch.setenv("VOCAPHONE_TOKEN", secret)
    monkeypatch.setattr("sys.argv", ["vocaphone-token", "--plain"])

    cli.token()

    assert capsys.readouterr().out == secret + "\n"


def test_token_blank_token_file_env_falls_back_to_default(
    tmp_path: Path, monkeypatch: MonkeyPatch, capsys: CaptureFixture[str]
) -> None:
    home = _isolate_home(monkeypatch, tmp_path)
    secret = _write_token(home)
    # Same rule as Settings.from_env / the old just recipe: blank means unset.
    monkeypatch.setenv("VOCAPHONE_TOKEN_FILE", "   ")
    monkeypatch.setattr("sys.argv", ["vocaphone-token", "--plain"])

    cli.token()

    assert capsys.readouterr().out == secret + "\n"


def test_token_missing_file_exits(
    tmp_path: Path, monkeypatch: MonkeyPatch, capsys: CaptureFixture[str]
) -> None:
    _isolate_home(monkeypatch, tmp_path)
    monkeypatch.setattr("sys.argv", ["vocaphone-token", "--plain"])

    with pytest.raises(SystemExit) as exc:
        cli.token()

    assert exc.value.code == 1
    assert "No token yet" in capsys.readouterr().err


def test_token_tty_prints_pairing_qr(
    tmp_path: Path, monkeypatch: MonkeyPatch, capsys: CaptureFixture[str]
) -> None:
    home = _isolate_home(monkeypatch, tmp_path)
    secret = _write_token(home)
    monkeypatch.setenv("VOCAPHONE_PUBLIC_URL", "http://192.168.1.20:8765")
    monkeypatch.setattr("sys.argv", ["vocaphone-token"])
    monkeypatch.setattr("sys.stdout.isatty", lambda: True)

    cli.token()

    out = capsys.readouterr().out
    assert secret in out
    assert "http://192.168.1.20:8765" in out
    assert "Scan with the phone app" in out
    assert any(ch in out for ch in ("█", "▀", "▄", "#", "*"))


def test_token_tty_prefers_saved_webui_pairing_url(
    tmp_path: Path, monkeypatch: MonkeyPatch, capsys: CaptureFixture[str]
) -> None:
    home = _isolate_home(monkeypatch, tmp_path)
    secret = _write_token(home)
    config_path = home / ".config" / "vocaphone" / "config.json"
    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text(
        json.dumps({"pairing_url": "https://dictation.example.com"}),
        encoding="utf-8",
    )
    # Env discovery would prefer LAN; saved WebUI choice must win (Overview card).
    monkeypatch.setenv("VOCAPHONE_PUBLIC_URL", "http://192.168.1.20:8765")
    monkeypatch.setattr("sys.argv", ["vocaphone-token"])
    monkeypatch.setattr("sys.stdout.isatty", lambda: True)

    cli.token()

    out = capsys.readouterr().out
    assert secret in out
    assert "https://dictation.example.com" in out
    assert "192.168.1.20" not in out


def test_token_tty_without_gateway_warns(
    tmp_path: Path, monkeypatch: MonkeyPatch, capsys: CaptureFixture[str]
) -> None:
    home = _isolate_home(monkeypatch, tmp_path)
    secret = _write_token(home)
    monkeypatch.setattr("sys.argv", ["vocaphone-token"])
    monkeypatch.setattr("sys.stdout.isatty", lambda: True)
    monkeypatch.setattr("app.cli.default_pairing_url", lambda _port, **_kwargs: None)

    cli.token()

    captured = capsys.readouterr()
    assert secret in captured.out
    assert "No phone-reachable gateway address" in captured.err
