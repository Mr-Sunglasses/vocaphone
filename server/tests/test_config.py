from __future__ import annotations

from pytest import MonkeyPatch

from app.config import Settings, format_host_port, local_webui_url


def test_environment_defaults_to_all_interface_listener(monkeypatch: MonkeyPatch) -> None:
    monkeypatch.setenv("VOCAPHONE_TOKEN", "test-" + ("x" * 48))
    monkeypatch.delenv("VOCAPHONE_BIND_HOST", raising=False)

    settings = Settings.from_env()

    assert settings.bind_host == "0.0.0.0"
    assert format_host_port(settings.bind_host, settings.port) == "0.0.0.0:8765"
    assert local_webui_url(settings.bind_host, settings.port) == "http://127.0.0.1:8765/"


def test_ipv6_listener_and_local_url_are_bracketed() -> None:
    assert format_host_port("::", 8765) == "[::]:8765"
    assert local_webui_url("::", 8765) == "http://[::1]:8765/"
