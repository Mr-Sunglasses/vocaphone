from __future__ import annotations


class APIProblem(Exception):
    def __init__(
        self,
        status_code: int,
        code: str,
        message: str,
        *,
        recoverable: bool = False,
    ) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message
        self.recoverable = recoverable


class InvalidAudioError(Exception):
    pass


class SilentAudioError(InvalidAudioError):
    pass


class EngineUnavailableError(Exception):
    pass


class TranscriptionProcessError(Exception):
    pass
