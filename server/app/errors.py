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


class LanguageUnsupportedError(TranscriptionProcessError):
    """The request asked for a language the loaded model cannot transcribe.

    A subclass so any handler that only knows about `TranscriptionProcessError`
    still catches it, but it gets its own error code because retrying is futile:
    the fix is to choose a different language or load a different model.
    """
