from __future__ import annotations

from app.metrics import RuntimeMetrics


def test_runtime_metrics_track_work_and_outcomes() -> None:
    metrics = RuntimeMetrics(concurrency_limit=2)

    metrics.queued()
    assert metrics.snapshot().queue_depth == 1

    metrics.started()
    metrics.succeeded(120)
    metrics.finished()

    metrics.queued()
    metrics.started()
    metrics.failed(280)
    metrics.finished()

    metrics.queued()
    metrics.rejected()
    metrics.queued()
    metrics.cancelled()
    snapshot = metrics.snapshot()

    assert snapshot.queue_depth == 0
    assert snapshot.active_transcriptions == 0
    assert snapshot.concurrency_limit == 2
    assert snapshot.successful_transcriptions == 1
    assert snapshot.failed_transcriptions == 1
    assert snapshot.rejected_transcriptions == 1
    assert snapshot.average_latency_ms == 200
    assert snapshot.last_latency_ms == 280
