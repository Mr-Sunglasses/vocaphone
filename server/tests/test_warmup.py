from __future__ import annotations

from pathlib import Path

from app.models.warmup import prefetch_model_paths


def test_prefetch_a_single_file_advises_its_full_size(tmp_path: Path) -> None:
    path = tmp_path / "model.bin"
    path.write_bytes(b"x" * 4096)

    assert prefetch_model_paths([path]) == 4096


def test_prefetch_walks_directories_for_files(tmp_path: Path) -> None:
    directory = tmp_path / "model"
    directory.mkdir()
    (directory / "weights.bin").write_bytes(b"x" * 1024)
    (directory / "tokenizer.json").write_bytes(b"y" * 256)

    assert prefetch_model_paths([directory]) == 1024 + 256


def test_prefetch_skips_paths_that_do_not_exist(tmp_path: Path) -> None:
    assert prefetch_model_paths([tmp_path / "does-not-exist"]) == 0


def test_prefetch_stops_once_the_byte_budget_is_reached(tmp_path: Path) -> None:
    large = tmp_path / "large.bin"
    large.write_bytes(b"x" * 4096)
    small = tmp_path / "small.bin"
    small.write_bytes(b"y" * 1024)

    advised = prefetch_model_paths([large, small], maximum_bytes=2048)

    assert advised == 2048


def test_prefetch_with_no_candidates_advises_nothing(tmp_path: Path) -> None:
    assert prefetch_model_paths([]) == 0
