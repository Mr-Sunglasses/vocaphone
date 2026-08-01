from __future__ import annotations

import asyncio
import time
from dataclasses import dataclass
from typing import Literal, Protocol, runtime_checkable

from app.engines import EngineProvider
from app.models.base import EngineHealth, TranscriptionEngine

WarmupState = Literal["pending", "warming", "complete", "unsupported", "unavailable", "failed"]


@runtime_checkable
class WarmableEngine(Protocol):
    async def warmup(self) -> int: ...


@dataclass(frozen=True, slots=True)
class ReadinessDetails:
    health: EngineHealth
    checked_age_seconds: float
    warmup_state: WarmupState
    warmed_bytes: int


class ReadinessMonitor:
    """Caches inexpensive engine probes and coordinates best-effort model prefetching."""

    def __init__(self, provider: EngineProvider, ttl_seconds: float = 5.0) -> None:
        self.provider = provider
        self.ttl_seconds = ttl_seconds
        self._lock = asyncio.Lock()
        self._engine: TranscriptionEngine | None = None
        self._health: EngineHealth | None = None
        self._checked_at = 0.0
        self._warmup_state: WarmupState = "pending"
        self._warmed_bytes = 0

    async def probe(self, *, force: bool = False) -> EngineHealth:
        engine = self.provider.current()
        now = time.monotonic()
        if self._engine is not engine:
            self._reset_for_engine(engine)
        if not force and self._health is not None and now - self._checked_at < self.ttl_seconds:
            return self._health
        async with self._lock:
            engine = self.provider.current()
            now = time.monotonic()
            if self._engine is not engine:
                self._reset_for_engine(engine)
            if not force and self._health is not None and now - self._checked_at < self.ttl_seconds:
                return self._health
            try:
                health = await engine.health()
            except Exception:
                health = EngineHealth(ready=False, name=type(engine).__name__)
            self._engine = engine
            self._health = health
            self._checked_at = time.monotonic()
            return health

    async def warmup(self) -> None:
        engine = self.provider.current()
        if self._engine is not engine:
            self._reset_for_engine(engine)
        self._warmup_state = "warming"
        health = await self.probe(force=True)
        if not health.ready:
            self._warmup_state = "unavailable"
            return
        if not isinstance(engine, WarmableEngine):
            self._warmup_state = "unsupported"
            return
        try:
            warmed_bytes = await engine.warmup()
        except Exception:
            if self.provider.current() is engine:
                self._warmup_state = "failed"
            return
        if self.provider.current() is engine:
            self._warmed_bytes = warmed_bytes
            self._warmup_state = "complete" if warmed_bytes > 0 else "unsupported"
            await self.probe(force=True)

    async def details(self) -> ReadinessDetails:
        health = await self.probe()
        age = max(0.0, time.monotonic() - self._checked_at)
        return ReadinessDetails(
            health=health,
            checked_age_seconds=age,
            warmup_state=self._warmup_state,
            warmed_bytes=self._warmed_bytes,
        )

    def _reset_for_engine(self, engine: TranscriptionEngine) -> None:
        self._engine = engine
        self._health = None
        self._checked_at = 0.0
        self._warmup_state = "pending"
        self._warmed_bytes = 0
