from __future__ import annotations

import threading
import time
from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class MetricsSnapshot:
    uptime_seconds: int
    queue_depth: int
    active_transcriptions: int
    concurrency_limit: int
    successful_transcriptions: int
    failed_transcriptions: int
    rejected_transcriptions: int
    average_latency_ms: int | None
    last_latency_ms: int | None


class RuntimeMetrics:
    """Small, privacy-safe in-memory counters scoped to one server process."""

    def __init__(self, concurrency_limit: int) -> None:
        self._started_at = time.monotonic()
        self._concurrency_limit = concurrency_limit
        self._lock = threading.Lock()
        self._queue_depth = 0
        self._active_transcriptions = 0
        self._successful_transcriptions = 0
        self._failed_transcriptions = 0
        self._rejected_transcriptions = 0
        self._total_latency_ms = 0
        self._last_latency_ms: int | None = None

    def queued(self) -> None:
        with self._lock:
            self._queue_depth += 1

    def started(self) -> None:
        with self._lock:
            self._queue_depth = max(0, self._queue_depth - 1)
            self._active_transcriptions += 1

    def rejected(self) -> None:
        with self._lock:
            self._queue_depth = max(0, self._queue_depth - 1)
            self._rejected_transcriptions += 1

    def cancelled(self) -> None:
        with self._lock:
            self._queue_depth = max(0, self._queue_depth - 1)

    def succeeded(self, latency_ms: int) -> None:
        with self._lock:
            self._successful_transcriptions += 1
            self._record_latency(latency_ms)

    def failed(self, latency_ms: int) -> None:
        with self._lock:
            self._failed_transcriptions += 1
            self._record_latency(latency_ms)

    def finished(self) -> None:
        with self._lock:
            self._active_transcriptions = max(0, self._active_transcriptions - 1)

    def snapshot(self) -> MetricsSnapshot:
        with self._lock:
            completed = self._successful_transcriptions + self._failed_transcriptions
            average = round(self._total_latency_ms / completed) if completed else None
            return MetricsSnapshot(
                uptime_seconds=max(0, int(time.monotonic() - self._started_at)),
                queue_depth=self._queue_depth,
                active_transcriptions=self._active_transcriptions,
                concurrency_limit=self._concurrency_limit,
                successful_transcriptions=self._successful_transcriptions,
                failed_transcriptions=self._failed_transcriptions,
                rejected_transcriptions=self._rejected_transcriptions,
                average_latency_ms=average,
                last_latency_ms=self._last_latency_ms,
            )

    def _record_latency(self, latency_ms: int) -> None:
        safe_latency = max(0, latency_ms)
        self._total_latency_ms += safe_latency
        self._last_latency_ms = safe_latency
