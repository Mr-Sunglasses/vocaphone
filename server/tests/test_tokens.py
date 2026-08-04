from __future__ import annotations

from pathlib import Path

from app.tokens import TokenStore


def test_create_returns_plaintext_once_and_matches_validates_it(tmp_path: Path) -> None:
    store = TokenStore(tmp_path / "device_tokens.json")
    record, plaintext = store.create("Kanishk's iPhone")
    assert record.label == "Kanishk's iPhone"
    assert store.matches(plaintext) is True
    assert store.matches("wrong-token") is False
    assert store.matches("") is False
    # The plaintext is never persisted, only its hash.
    assert plaintext not in (tmp_path / "device_tokens.json").read_text(encoding="utf-8")


def test_revoke_removes_a_token(tmp_path: Path) -> None:
    store = TokenStore(tmp_path / "device_tokens.json")
    record, plaintext = store.create("Pixel 6a")
    assert store.matches(plaintext) is True
    assert store.revoke(record.id) is True
    assert store.matches(plaintext) is False
    assert store.revoke(record.id) is False


def test_revoke_unknown_id_returns_false(tmp_path: Path) -> None:
    store = TokenStore(tmp_path / "device_tokens.json")
    assert store.revoke("does-not-exist") is False


def test_tokens_persist_across_store_instances(tmp_path: Path) -> None:
    path = tmp_path / "device_tokens.json"
    first = TokenStore(path)
    _, plaintext = first.create("Work laptop")

    second = TokenStore(path)
    assert len(second.all()) == 1
    assert second.matches(plaintext) is True


def test_missing_or_corrupt_file_yields_empty_store(tmp_path: Path) -> None:
    missing = TokenStore(tmp_path / "does-not-exist.json")
    assert missing.all() == []

    corrupt_path = tmp_path / "corrupt.json"
    corrupt_path.write_text("not json", encoding="utf-8")
    corrupt = TokenStore(corrupt_path)
    assert corrupt.all() == []


def test_blank_label_defaults_to_unnamed_device(tmp_path: Path) -> None:
    store = TokenStore(tmp_path / "device_tokens.json")
    record, _ = store.create("   ")
    assert record.label == "Unnamed device"


def test_cached_plaintext_available_after_create_and_gone_after_revoke(tmp_path: Path) -> None:
    store = TokenStore(tmp_path / "device_tokens.json")
    record, plaintext = store.create("iPad")
    assert store.cached_plaintext(record.id) == plaintext
    assert [entry.id for entry in store.cached_entries()] == [record.id]

    store.revoke(record.id)
    assert store.cached_plaintext(record.id) is None
    assert store.cached_entries() == []


def test_cache_does_not_survive_a_fresh_store_instance(tmp_path: Path) -> None:
    path = tmp_path / "device_tokens.json"
    first = TokenStore(path)
    record, _ = first.create("Old laptop")

    second = TokenStore(path)
    assert second.cached_plaintext(record.id) is None
    assert second.cached_entries() == []
