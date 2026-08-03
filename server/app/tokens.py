"""Named, individually revocable bearer tokens for additional paired devices.

`Settings.token` (from `LOCALFLOW_TOKEN` / the token file) remains a permanent
bootstrap credential managed outside this store — whoever controls that file
or environment variable can always read/rotate it directly, so trying to
revoke it through the API would be theatre. Everything issued through
`TokenStore` sits alongside it and can be revoked independently, so losing one
phone means revoking one token rather than rotating everyone else's.

Only a SHA-256 digest of each token is ever persisted; the plaintext is
returned once, at creation, and is not recoverable afterward. To let a device
token's own QR be regenerated (for example after changing the pairing
address) without weakening that guarantee, the store also keeps an in-memory,
never-persisted cache of recently created plaintexts, cleared on revoke and
naturally gone on restart.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import secrets
import tempfile
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path


@dataclass(frozen=True, slots=True)
class DeviceToken:
    id: str
    label: str
    token_hash: str
    created_at: datetime


def _hash_token(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


class TokenStore:
    def __init__(self, path: Path) -> None:
        self._path = path
        self._tokens: list[DeviceToken] = self._load(path)
        self._plaintext_cache: dict[str, str] = {}

    @staticmethod
    def _load(path: Path) -> list[DeviceToken]:
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return []
        if not isinstance(payload, list):
            return []
        tokens: list[DeviceToken] = []
        for entry in payload:
            if not isinstance(entry, dict):
                continue
            token_id = entry.get("id")
            label = entry.get("label")
            token_hash = entry.get("token_hash")
            created_at = entry.get("created_at")
            if not (
                isinstance(token_id, str)
                and token_id
                and isinstance(label, str)
                and label
                and isinstance(token_hash, str)
                and token_hash
                and isinstance(created_at, str)
            ):
                continue
            try:
                parsed_created_at = datetime.fromisoformat(created_at)
            except ValueError:
                continue
            tokens.append(
                DeviceToken(
                    id=token_id, label=label, token_hash=token_hash, created_at=parsed_created_at
                )
            )
        return tokens

    def _save(self) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        payload = [
            {
                "id": token.id,
                "label": token.label,
                "token_hash": token.token_hash,
                "created_at": token.created_at.isoformat(),
            }
            for token in self._tokens
        ]
        descriptor, temporary_name = tempfile.mkstemp(
            dir=self._path.parent, prefix=".device-tokens-", suffix=".tmp"
        )
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(payload, handle, indent=2)
                handle.write("\n")
            os.replace(temporary_name, self._path)
        except BaseException:
            Path(temporary_name).unlink(missing_ok=True)
            raise

    def all(self) -> list[DeviceToken]:
        return list(self._tokens)

    def create(self, label: str) -> tuple[DeviceToken, str]:
        plaintext = secrets.token_urlsafe(32)
        record = DeviceToken(
            id=secrets.token_hex(8),
            label=label.strip() or "Unnamed device",
            token_hash=_hash_token(plaintext),
            created_at=datetime.now(UTC),
        )
        self._tokens.append(record)
        self._save()
        self._plaintext_cache[record.id] = plaintext
        return record, plaintext

    def get(self, token_id: str) -> DeviceToken | None:
        return next((token for token in self._tokens if token.id == token_id), None)

    def rotate(self, token_id: str) -> tuple[DeviceToken, str] | None:
        """Replace *token_id*'s secret in place, keeping its id and label.

        The previous plaintext stops working immediately (its hash is gone),
        so this is only for a token whose plaintext can no longer be
        displayed — for example after a restart cleared the cache below.
        """
        for index, token in enumerate(self._tokens):
            if token.id != token_id:
                continue
            plaintext = secrets.token_urlsafe(32)
            updated = DeviceToken(
                id=token.id,
                label=token.label,
                token_hash=_hash_token(plaintext),
                created_at=datetime.now(UTC),
            )
            self._tokens[index] = updated
            self._save()
            self._plaintext_cache[token.id] = plaintext
            return updated, plaintext
        return None

    def revoke(self, token_id: str) -> bool:
        remaining = [token for token in self._tokens if token.id != token_id]
        if len(remaining) == len(self._tokens):
            return False
        self._tokens = remaining
        self._save()
        self._plaintext_cache.pop(token_id, None)
        return True

    def matches(self, candidate: str) -> bool:
        if not candidate:
            return False
        candidate_hash = _hash_token(candidate)
        return any(hmac.compare_digest(token.token_hash, candidate_hash) for token in self._tokens)

    def cached_plaintext(self, token_id: str) -> str | None:
        """The plaintext for *token_id*, if created (and not revoked) in this process."""
        return self._plaintext_cache.get(token_id)

    def cached_entries(self) -> list[DeviceToken]:
        """Device tokens whose plaintext is still available for QR display."""
        return [token for token in self._tokens if token.id in self._plaintext_cache]
