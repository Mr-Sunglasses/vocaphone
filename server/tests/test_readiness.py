from __future__ import annotations

from pathlib import Path

from app.engines import StaticEngineProvider
from app.models.base import EngineHealth, TranscriptionOptions
from app.readiness import ReadinessMonitor


class WarmableFakeEngine:
    def __init__(self) -> None:
        self.health_calls = 0
        self.warmup_calls = 0

    async def health(self) -> EngineHealth:
        self.health_calls += 1
        return EngineHealth(ready=True, name="warmable-fake")

    async def warmup(self) -> int:
        self.warmup_calls += 1
        return 1024

    async def transcribe(self, audio_path: Path, options: TranscriptionOptions) -> str:
        return "unused"


async def test_readiness_caches_probes_and_tracks_warmup() -> None:
    engine = WarmableFakeEngine()
    monitor = ReadinessMonitor(StaticEngineProvider(engine), ttl_seconds=30)

    first = await monitor.probe()
    second = await monitor.probe()
    await monitor.warmup()
    details = await monitor.details()

    assert first.ready is True
    assert second == first
    assert engine.health_calls == 3
    assert engine.warmup_calls == 1
    assert details.warmup_state == "complete"
    assert details.warmed_bytes == 1024
