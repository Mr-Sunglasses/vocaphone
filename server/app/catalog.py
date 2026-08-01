from __future__ import annotations

from dataclasses import dataclass

from app.system import SystemInfo

ENGINE_WHISPER_CPP = "whisper.cpp"
ENGINE_WHISPERKIT = "whisperkit"
ENGINE_FASTER_WHISPER = "faster-whisper"
ENGINE_MOONSHINE = "moonshine"

WHISPER_CPP_REPO = "ggerganov/whisper.cpp"
WHISPERKIT_REPO = "argmaxinc/whisperkit-coreml"

MB = 1_000_000
GB = 1_000_000_000


@dataclass(frozen=True, slots=True)
class CatalogModel:
    """A downloadable speech-to-text model."""

    id: str
    engine: str
    key: str
    label: str
    size_bytes: int
    languages: str
    quality: str
    minimum_ram_gb: float
    download_url: str | None = None
    huggingface_repo: str | None = None
    huggingface_folder: str | None = None
    family: str = "Whisper"
    description: str = "Local speech recognition model."
    source: str = "whisper.cpp"
    marker_file: str | None = None


def _whisper_cpp(
    key: str,
    label: str,
    size_bytes: int,
    languages: str,
    quality: str,
    minimum_ram_gb: float,
    *,
    download_url: str | None = None,
    family: str = "Whisper",
    description: str = "OpenAI Whisper converted for the standalone whisper.cpp engine.",
    source: str = "whisper.cpp",
) -> CatalogModel:
    return CatalogModel(
        id=f"{ENGINE_WHISPER_CPP}:{key}",
        engine=ENGINE_WHISPER_CPP,
        key=key,
        label=label,
        size_bytes=size_bytes,
        languages=languages,
        quality=quality,
        minimum_ram_gb=minimum_ram_gb,
        download_url=download_url
        or f"https://huggingface.co/{WHISPER_CPP_REPO}/resolve/main/{key}",
        family=family,
        description=description,
        source=source,
    )


def _whisperkit(
    folder: str,
    label: str,
    size_bytes: int,
    languages: str,
    quality: str,
    minimum_ram_gb: float,
) -> CatalogModel:
    return CatalogModel(
        id=f"{ENGINE_WHISPERKIT}:{folder}",
        engine=ENGINE_WHISPERKIT,
        key=folder,
        label=label,
        size_bytes=size_bytes,
        languages=languages,
        quality=quality,
        minimum_ram_gb=minimum_ram_gb,
        huggingface_repo=WHISPERKIT_REPO,
        huggingface_folder=folder,
        family="Whisper",
        description="Core ML Whisper model optimized for Apple silicon.",
        source="WhisperKit",
    )


def _faster_whisper(
    key: str,
    label: str,
    size_bytes: int,
    languages: str,
    quality: str,
    minimum_ram_gb: float,
) -> CatalogModel:
    repository = (
        f"Systran/faster-distil-whisper-{key.removeprefix('distil-')}"
        if key.startswith("distil-")
        else f"Systran/faster-whisper-{key}"
    )
    return CatalogModel(
        id=f"{ENGINE_FASTER_WHISPER}:{key}",
        engine=ENGINE_FASTER_WHISPER,
        key=key,
        label=label,
        size_bytes=size_bytes,
        languages=languages,
        quality=quality,
        minimum_ram_gb=minimum_ram_gb,
        huggingface_repo=repository,
        huggingface_folder="",
        family="Whisper / CTranslate2",
        description=(
            "Persistent CTranslate2 model with CPU INT8 inference; optimized for Linux servers."
        ),
        source="faster-whisper",
        marker_file="model.bin",
    )


def _moonshine(
    language: str,
    label: str,
    size_bytes: int,
    languages: str,
) -> CatalogModel:
    return CatalogModel(
        id=f"{ENGINE_MOONSHINE}:{language}",
        engine=ENGINE_MOONSHINE,
        key=language,
        label=label,
        size_bytes=size_bytes,
        languages=languages,
        quality="Low-latency streaming",
        minimum_ram_gb=4,
        family="Moonshine",
        description=(
            "Experimental model designed for real-time local dictation and incremental audio."
        ),
        source="Moonshine Voice",
        marker_file=".localflow-model.json",
    )


DEFAULT_CATALOG: tuple[CatalogModel, ...] = (
    _moonshine("en", "Moonshine English", 245 * MB, "English only"),
    _faster_whisper("tiny.en", "faster-whisper Tiny EN", 75 * MB, "English only", "Fastest", 2),
    _faster_whisper("tiny", "faster-whisper Tiny", 75 * MB, "Multilingual", "Fastest", 2),
    _faster_whisper("base.en", "faster-whisper Base EN", 145 * MB, "English only", "Fast", 3),
    _faster_whisper("base", "faster-whisper Base", 145 * MB, "Multilingual", "Fast", 3),
    _faster_whisper("small.en", "faster-whisper Small EN", 484 * MB, "English only", "Balanced", 6),
    _faster_whisper("small", "faster-whisper Small", 484 * MB, "Multilingual", "Balanced", 6),
    _faster_whisper(
        "distil-small.en",
        "Distil-Whisper Small EN",
        332 * MB,
        "English only",
        "Fast · distilled",
        5,
    ),
    _faster_whisper(
        "distil-medium.en",
        "Distil-Whisper Medium EN",
        789 * MB,
        "English only",
        "Accurate · distilled",
        8,
    ),
    _whisperkit("openai_whisper-tiny", "WhisperKit Tiny", 66 * MB, "Multilingual", "Fastest", 4),
    _whisperkit(
        "openai_whisper-tiny.en", "WhisperKit Tiny EN", 66 * MB, "English only", "Fastest", 4
    ),
    _whisperkit("openai_whisper-base", "WhisperKit Base", 145 * MB, "Multilingual", "Fast", 4),
    _whisperkit(
        "openai_whisper-base.en", "WhisperKit Base EN", 145 * MB, "English only", "Fast", 4
    ),
    _whisperkit(
        "openai_whisper-small_216MB",
        "WhisperKit Small (compressed)",
        216 * MB,
        "Multilingual",
        "Balanced",
        8,
    ),
    _whisperkit(
        "openai_whisper-small", "WhisperKit Small", 484 * MB, "Multilingual", "Balanced", 8
    ),
    _whisperkit(
        "openai_whisper-large-v3-v20240930_626MB",
        "WhisperKit Large v3 Turbo (compressed)",
        626 * MB,
        "Multilingual",
        "Most accurate",
        12,
    ),
    _whisperkit(
        "openai_whisper-large-v3-v20240930_turbo",
        "WhisperKit Large v3 Turbo",
        1610 * MB,
        "Multilingual",
        "Most accurate",
        16,
    ),
    _whisper_cpp("ggml-tiny.en.bin", "whisper.cpp Tiny EN", 75 * MB, "English only", "Fastest", 4),
    _whisper_cpp("ggml-tiny.bin", "whisper.cpp Tiny", 75 * MB, "Multilingual", "Fastest", 4),
    _whisper_cpp("ggml-base.en.bin", "whisper.cpp Base EN", 142 * MB, "English only", "Fast", 4),
    _whisper_cpp("ggml-base.bin", "whisper.cpp Base", 142 * MB, "Multilingual", "Fast", 4),
    _whisper_cpp(
        "ggml-small.en.bin", "whisper.cpp Small EN", 466 * MB, "English only", "Balanced", 8
    ),
    _whisper_cpp("ggml-small.bin", "whisper.cpp Small", 466 * MB, "Multilingual", "Balanced", 8),
    _whisper_cpp(
        "ggml-medium.en.bin", "whisper.cpp Medium EN", 1500 * MB, "English only", "Accurate", 12
    ),
    _whisper_cpp(
        "ggml-medium.bin", "whisper.cpp Medium", 1500 * MB, "Multilingual", "Accurate", 12
    ),
    _whisper_cpp(
        "whisper-medium-q4_1.bin",
        "Whisper Medium Q4",
        492 * MB,
        "Multilingual",
        "Accurate · compact",
        8,
        download_url="https://blob.handy.computer/whisper-medium-q4_1.bin",
        description="Handy's compact Whisper Medium build, usable without the Handy app.",
        source="Handy-compatible",
    ),
    _whisper_cpp(
        "ggml-large-v3-turbo.bin",
        "whisper.cpp Large v3 Turbo",
        1620 * MB,
        "Multilingual",
        "Most accurate",
        16,
    ),
    _whisper_cpp(
        "ggml-large-v3-q5_0.bin",
        "Whisper Large v3 Q5",
        1081 * MB,
        "Multilingual",
        "Most accurate · compact",
        16,
        download_url="https://blob.handy.computer/ggml-large-v3-q5_0.bin",
        description="Quantized Whisper Large v3 from Handy's standalone model catalog.",
        source="Handy-compatible",
    ),
    _whisper_cpp(
        "breeze-asr-q5_k.bin",
        "Breeze ASR Q5",
        1081 * MB,
        "Taiwanese Mandarin + English",
        "Specialized",
        16,
        download_url="https://blob.handy.computer/breeze-asr-q5_k.bin",
        family="Breeze ASR",
        description="Whisper variant tuned for Taiwanese Mandarin and code-switching.",
        source="Handy-compatible",
    ),
    _whisper_cpp(
        "ggml-large-v3.bin", "whisper.cpp Large v3", 3 * GB, "Multilingual", "Most accurate", 24
    ),
)


def catalog_by_id(catalog: tuple[CatalogModel, ...] = DEFAULT_CATALOG) -> dict[str, CatalogModel]:
    return {model.id: model for model in catalog}


def recommended_ids(system: SystemInfo) -> set[str]:
    """Pick the models that best fit this machine."""
    preferred_engine = ENGINE_WHISPERKIT if system.is_apple_silicon else ENGINE_FASTER_WHISPER
    ram = system.ram_gb or 8.0
    if ram >= 16:
        if preferred_engine == ENGINE_WHISPERKIT:
            return {
                f"{ENGINE_WHISPERKIT}:openai_whisper-large-v3-v20240930_626MB",
                f"{ENGINE_WHISPERKIT}:openai_whisper-large-v3-v20240930_turbo",
            }
        return {
            f"{ENGINE_FASTER_WHISPER}:small",
            f"{ENGINE_FASTER_WHISPER}:distil-medium.en",
        }
    if ram >= 8:
        if preferred_engine == ENGINE_WHISPERKIT:
            return {f"{ENGINE_WHISPERKIT}:openai_whisper-small_216MB"}
        return {
            f"{ENGINE_FASTER_WHISPER}:base",
            f"{ENGINE_FASTER_WHISPER}:distil-small.en",
        }
    if preferred_engine == ENGINE_WHISPERKIT:
        return {f"{ENGINE_WHISPERKIT}:openai_whisper-base"}
    return {f"{ENGINE_FASTER_WHISPER}:tiny"}
