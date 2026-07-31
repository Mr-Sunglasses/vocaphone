from __future__ import annotations

import secrets
import sqlite3
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import UUID


@dataclass(slots=True)
class StoredSession:
    session_id: UUID
    job_id: str
    state: str
    language: str
    style: str
    audio_name: str | None
    transcript: str | None
    error_code: str | None
    created_at: datetime
    updated_at: datetime


class SessionRepository:
    def __init__(self, database_path: Path) -> None:
        self.database_path = database_path

    def initialize(self) -> None:
        self.database_path.parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as connection:
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS sessions (
                    session_id TEXT PRIMARY KEY,
                    job_id TEXT NOT NULL UNIQUE,
                    state TEXT NOT NULL,
                    language TEXT NOT NULL,
                    style TEXT NOT NULL,
                    audio_name TEXT,
                    transcript TEXT,
                    error_code TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """
            )

    def create_or_get(self, session_id: UUID, language: str, style: str) -> StoredSession:
        existing = self.get(session_id)
        if existing is not None:
            return existing
        now = datetime.now(UTC)
        with self._connect() as connection:
            connection.execute(
                """
                INSERT OR IGNORE INTO sessions
                (session_id, job_id, state, language, style, created_at, updated_at)
                VALUES (?, ?, 'created', ?, ?, ?, ?)
                """,
                (
                    str(session_id),
                    secrets.token_urlsafe(24),
                    language,
                    style,
                    now.isoformat(),
                    now.isoformat(),
                ),
            )
        result = self.get(session_id)
        if result is None:
            raise RuntimeError("Session creation failed")
        return result

    def get(self, session_id: UUID) -> StoredSession | None:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT * FROM sessions WHERE session_id = ?", (str(session_id),)
            ).fetchone()
        return self._from_row(row) if row else None

    def update(
        self,
        session_id: UUID,
        *,
        state: str,
        audio_name: str | None = None,
        transcript: str | None = None,
        error_code: str | None = None,
        preserve_audio_name: bool = True,
    ) -> StoredSession:
        current = self.get(session_id)
        if current is None:
            raise KeyError(session_id)
        chosen_audio = (
            current.audio_name if preserve_audio_name and audio_name is None else audio_name
        )
        now = datetime.now(UTC)
        with self._connect() as connection:
            connection.execute(
                """
                UPDATE sessions
                SET state = ?, audio_name = ?, transcript = ?, error_code = ?, updated_at = ?
                WHERE session_id = ?
                """,
                (
                    state,
                    chosen_audio,
                    transcript,
                    error_code,
                    now.isoformat(),
                    str(session_id),
                ),
            )
        result = self.get(session_id)
        if result is None:
            raise RuntimeError("Session update failed")
        return result

    def delete(self, session_id: UUID) -> StoredSession | None:
        current = self.get(session_id)
        if current is None:
            return None
        with self._connect() as connection:
            connection.execute("DELETE FROM sessions WHERE session_id = ?", (str(session_id),))
        return current

    def expired(self, retention_hours: int) -> list[StoredSession]:
        cutoff = datetime.now(UTC) - timedelta(hours=retention_hours)
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT * FROM sessions WHERE updated_at < ?", (cutoff.isoformat(),)
            ).fetchall()
        return [self._from_row(row) for row in rows]

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.database_path, timeout=10)
        connection.row_factory = sqlite3.Row
        return connection

    @staticmethod
    def _from_row(row: sqlite3.Row) -> StoredSession:
        return StoredSession(
            session_id=UUID(row["session_id"]),
            job_id=row["job_id"],
            state=row["state"],
            language=row["language"],
            style=row["style"],
            audio_name=row["audio_name"],
            transcript=row["transcript"],
            error_code=row["error_code"],
            created_at=datetime.fromisoformat(row["created_at"]),
            updated_at=datetime.fromisoformat(row["updated_at"]),
        )
