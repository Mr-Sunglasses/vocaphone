from __future__ import annotations

from dataclasses import dataclass

from app.system import SystemInfo

ENGINE_WHISPER_CPP = "whisper.cpp"
ENGINE_WHISPERKIT = "whisperkit"
ENGINE_FASTER_WHISPER = "faster-whisper"
ENGINE_MOONSHINE = "moonshine"
ENGINE_SHERPA_ONNX = "sherpa-onnx"
ENGINE_MLX_AUDIO = "mlx-audio"

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
    language_code: str | None = None
    model_arch: int | None = None
    supports_streaming: bool = False
    license_name: str = "See model source"
    commercial_use: bool = True
    archive_url: str | None = None
    archive_root: str | None = None
    required_files: tuple[str, ...] = ()
    model_type: str | None = None
    language_codes: tuple[str, ...] = ()
    apple_silicon_only: bool = False


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
    key: str,
    language: str,
    architecture: str,
    model_arch: int,
    label: str,
    size_bytes: int,
    quality: str,
    *,
    supports_streaming: bool = False,
    minimum_ram_gb: float = 2,
) -> CatalogModel:
    english = language == "en"
    return CatalogModel(
        id=f"{ENGINE_MOONSHINE}:{key}",
        engine=ENGINE_MOONSHINE,
        key=key,
        label=label,
        size_bytes=size_bytes,
        languages=f"{_MOONSHINE_LANGUAGE_NAMES[language]} only",
        quality=quality,
        minimum_ram_gb=minimum_ram_gb,
        family="Moonshine",
        description=(
            f"{architecture} model optimized for private local dictation."
            + (
                " Uses cached incremental inference while you speak."
                if supports_streaming
                else " Uses the fast batch pipeline after recording."
            )
        ),
        source="Moonshine Voice",
        marker_file=".localflow-model.json",
        language_code=language,
        model_arch=model_arch,
        supports_streaming=supports_streaming,
        license_name="MIT" if english else "Moonshine Community License",
        commercial_use=english,
    )


def _sherpa_onnx(
    key: str,
    label: str,
    size_bytes: int,
    languages: str,
    quality: str,
    minimum_ram_gb: float,
    *,
    required_files: tuple[str, ...],
    model_type: str,
    language_codes: tuple[str, ...],
    family: str,
    description: str,
    license_name: str,
    archive_url: str | None = None,
    archive_root: str | None = None,
    huggingface_repo: str | None = None,
    supports_streaming: bool = False,
) -> CatalogModel:
    """Build a sherpa-onnx catalog entry from either download mechanism.

    Most models ship as a `k2-fsa/sherpa-onnx` GitHub-release `.tar.bz2`
    (`archive_url`/`archive_root`). Some model families (GigaAM, Canary) are
    only published as individual files in a plain Hugging Face model repo with
    no such archive; for those, pass `huggingface_repo` instead and the
    gateway downloads exactly `required_files` from its root.
    """
    if archive_url is not None:
        if archive_root is None:
            raise ValueError(f"{key}: archive_url requires archive_root.")
    elif huggingface_repo is None:
        raise ValueError(f"{key}: provide either archive_url/archive_root or huggingface_repo.")
    return CatalogModel(
        id=f"{ENGINE_SHERPA_ONNX}:{key}",
        engine=ENGINE_SHERPA_ONNX,
        key=key,
        label=label,
        size_bytes=size_bytes,
        languages=languages,
        quality=quality,
        minimum_ram_gb=minimum_ram_gb,
        archive_url=archive_url,
        archive_root=archive_root,
        huggingface_repo=huggingface_repo,
        required_files=required_files,
        family=family,
        description=description,
        source="sherpa-onnx",
        marker_file=".localflow-model.json",
        model_type=model_type,
        language_codes=language_codes,
        license_name=license_name,
        supports_streaming=supports_streaming,
    )


def _mlx_audio(
    key: str,
    label: str,
    size_bytes: int,
    languages: str,
    quality: str,
    minimum_ram_gb: float,
    *,
    repository: str,
    family: str,
    description: str,
    license_name: str,
    language_codes: tuple[str, ...] = (),
) -> CatalogModel:
    return CatalogModel(
        id=f"{ENGINE_MLX_AUDIO}:{key}",
        engine=ENGINE_MLX_AUDIO,
        key=key,
        label=label,
        size_bytes=size_bytes,
        languages=languages,
        quality=quality,
        minimum_ram_gb=minimum_ram_gb,
        huggingface_repo=repository,
        huggingface_folder="",
        family=family,
        description=description,
        source="MLX Audio",
        marker_file="model.safetensors",
        language_codes=language_codes,
        apple_silicon_only=True,
        license_name=license_name,
    )


_MOONSHINE_LANGUAGE_NAMES = {
    "ar": "Arabic",
    "en": "English",
    "es": "Spanish",
    "ja": "Japanese",
    "ko": "Korean",
    "uk": "Ukrainian",
    "vi": "Vietnamese",
    "zh": "Mandarin Chinese",
}


DEFAULT_CATALOG: tuple[CatalogModel, ...] = (
    _sherpa_onnx(
        "sensevoice-small-int8",
        "SenseVoice Small INT8",
        240 * MB,
        "Mandarin, Cantonese, English, Japanese, Korean",
        "Fastest multilingual · punctuation",
        2,
        archive_url=(
            "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/"
            "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2"
        ),
        archive_root="sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17",
        required_files=("model.int8.onnx", "tokens.txt"),
        model_type="sense_voice",
        language_codes=("zh", "yue", "en", "ja", "ko"),
        family="SenseVoice",
        description=(
            "Compact non-autoregressive INT8 model for fast CPU dictation on Linux and macOS."
        ),
        license_name="FunASR Model License",
    ),
    _sherpa_onnx(
        "parakeet-tdt-0.6b-v3-int8",
        "Parakeet TDT 0.6B v3 INT8",
        672 * MB,
        "25 European languages",
        "Accurate multilingual · punctuation",
        4,
        archive_url=(
            "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/"
            "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2"
        ),
        archive_root="sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8",
        required_files=(
            "encoder.int8.onnx",
            "decoder.int8.onnx",
            "joiner.int8.onnx",
            "tokens.txt",
        ),
        model_type="nemo_transducer",
        language_codes=(
            "bg",
            "hr",
            "cs",
            "da",
            "nl",
            "en",
            "et",
            "fi",
            "fr",
            "de",
            "el",
            "hu",
            "it",
            "lv",
            "lt",
            "mt",
            "pl",
            "pt",
            "ro",
            "sk",
            "sl",
            "es",
            "sv",
            "ru",
            "uk",
        ),
        family="Parakeet TDT",
        description=(
            "NVIDIA's multilingual Parakeet converted to INT8 ONNX for fast macOS and Linux CPU "
            "inference."
        ),
        license_name="CC BY 4.0",
    ),
    _sherpa_onnx(
        "gigaam-v3-ctc-russian-int8",
        "GigaAM v3 CTC Russian INT8",
        225 * MB,
        "Russian only",
        "Fastest Russian ASR",
        2,
        huggingface_repo="csukuangfj/sherpa-onnx-nemo-ctc-giga-am-v3-russian-2025-12-16",
        required_files=("model.int8.onnx", "tokens.txt"),
        model_type="nemo_ctc",
        language_codes=("ru",),
        family="GigaAM",
        description=(
            "Sber's GigaAM CTC converted to INT8 ONNX for fast Russian-only CPU transcription."
        ),
        license_name="MIT",
    ),
    _sherpa_onnx(
        "gigaam-v3-rnnt-russian-int8",
        "GigaAM v3 RNNT Russian",
        230 * MB,
        "Russian only",
        "Most accurate Russian ASR",
        2,
        huggingface_repo="csukuangfj/sherpa-onnx-nemo-transducer-giga-am-v3-russian-2025-12-16",
        required_files=("encoder.int8.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"),
        model_type="nemo_transducer",
        language_codes=("ru",),
        family="GigaAM",
        description=(
            "Sber's GigaAM RNNT converted to ONNX for the most accurate Russian-only CPU "
            "transcription; only its encoder is INT8-quantized, so it is larger and slower "
            "than the CTC variant."
        ),
        license_name="MIT",
    ),
    _sherpa_onnx(
        "canary-180m-flash-en-int8",
        "Canary 180M Flash English INT8",
        210 * MB,
        "English only in this build",
        "Compact multilingual model, English transcription",
        2,
        huggingface_repo="csukuangfj/sherpa-onnx-nemo-canary-180m-flash-en-es-de-fr-int8",
        required_files=("encoder.int8.onnx", "decoder.int8.onnx", "tokens.txt"),
        model_type="nemo_canary",
        language_codes=("en",),
        family="Canary",
        description=(
            "NVIDIA's Canary 180M Flash converted to INT8 ONNX. The underlying model also "
            "covers German, French, and Spanish, but its source/target language is fixed when "
            "the recognizer loads rather than per request, so Local Flow loads it English-only "
            "for now."
        ),
        license_name="CC BY 4.0",
    ),
    _sherpa_onnx(
        "streaming-zipformer-en-20m-int8",
        "Streaming Zipformer English 20M INT8",
        44 * MB,
        "English only",
        "Fastest live streaming",
        1,
        huggingface_repo="csukuangfj/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17",
        required_files=(
            "encoder-epoch-99-avg-1.int8.onnx",
            "decoder-epoch-99-avg-1.int8.onnx",
            "joiner-epoch-99-avg-1.int8.onnx",
            "tokens.txt",
        ),
        model_type="streaming_zipformer",
        language_codes=("en",),
        family="Zipformer",
        description=(
            "A small streaming-capable zipformer transducer. Unlike the other sherpa-onnx "
            "models above, this one decodes incrementally over /v1/stream with real partial "
            "results, independent of Moonshine."
        ),
        license_name="Apache 2.0",
        supports_streaming=True,
    ),
    _mlx_audio(
        "whisper-large-v3-turbo-4bit",
        "MLX Whisper Large v3 Turbo 4-bit",
        469 * MB,
        "Multilingual",
        "Most accurate · compact",
        8,
        repository="mlx-community/whisper-large-v3-turbo-asr-4bit",
        family="Whisper / MLX",
        description=(
            "Quantized Whisper Large v3 Turbo running natively on Apple silicon through MLX."
        ),
        license_name="MIT",
    ),
    _mlx_audio(
        "parakeet-tdt-0.6b-v3",
        "MLX Parakeet TDT 0.6B v3",
        2510 * MB,
        "25 European languages",
        "Fast and accurate · punctuation",
        8,
        repository="mlx-community/parakeet-tdt-0.6b-v3",
        family="Parakeet TDT / MLX",
        description=(
            "Full-precision Parakeet optimized for the unified memory and GPU of M-series Macs."
        ),
        license_name="CC BY 4.0",
        language_codes=(
            "bg",
            "hr",
            "cs",
            "da",
            "nl",
            "en",
            "et",
            "fi",
            "fr",
            "de",
            "el",
            "hu",
            "it",
            "lv",
            "lt",
            "mt",
            "pl",
            "pt",
            "ro",
            "sk",
            "sl",
            "es",
            "sv",
            "ru",
            "uk",
        ),
    ),
    # Keep moonshine:en as the default English ID so existing installations and
    # runtime configuration continue to resolve after adding explicit variants.
    _moonshine(
        "en",
        "en",
        "Medium Streaming",
        5,
        "Moonshine English Medium Streaming",
        304 * MB,
        "Most accurate · cached streaming",
        supports_streaming=True,
        minimum_ram_gb=4,
    ),
    _moonshine(
        "en-small-streaming",
        "en",
        "Small Streaming",
        4,
        "Moonshine English Small Streaming",
        165 * MB,
        "Balanced · cached streaming",
        supports_streaming=True,
    ),
    _moonshine(
        "en-tiny-streaming",
        "en",
        "Tiny Streaming",
        2,
        "Moonshine English Tiny Streaming",
        52 * MB,
        "Fastest · cached streaming",
        supports_streaming=True,
    ),
    _moonshine("en-base", "en", "Base", 1, "Moonshine English Base", 141 * MB, "Accurate · batch"),
    _moonshine("en-tiny", "en", "Tiny", 0, "Moonshine English Tiny", 44 * MB, "Smallest · batch"),
    _moonshine("es", "es", "Base", 1, "Moonshine Spanish", 65 * MB, "Fast · batch"),
    _moonshine("ar", "ar", "Base", 1, "Moonshine Arabic", 141 * MB, "Fast · batch"),
    _moonshine("ja", "ja", "Base", 1, "Moonshine Japanese Base", 141 * MB, "Fast · batch"),
    _moonshine("ja-tiny", "ja", "Tiny", 0, "Moonshine Japanese Tiny", 72 * MB, "Fastest · batch"),
    _moonshine("ko", "ko", "Tiny", 0, "Moonshine Korean", 72 * MB, "Fastest · batch"),
    _moonshine("zh", "zh", "Base", 1, "Moonshine Mandarin", 141 * MB, "Fast · batch"),
    _moonshine("uk", "uk", "Base", 1, "Moonshine Ukrainian", 141 * MB, "Fast · batch"),
    _moonshine("vi", "vi", "Base", 1, "Moonshine Vietnamese", 141 * MB, "Fast · batch"),
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
                f"{ENGINE_MLX_AUDIO}:whisper-large-v3-turbo-4bit",
                f"{ENGINE_MLX_AUDIO}:parakeet-tdt-0.6b-v3",
            }
        return {
            f"{ENGINE_SHERPA_ONNX}:parakeet-tdt-0.6b-v3-int8",
            f"{ENGINE_FASTER_WHISPER}:small",
            f"{ENGINE_FASTER_WHISPER}:distil-medium.en",
        }
    if ram >= 8:
        if preferred_engine == ENGINE_WHISPERKIT:
            return {
                f"{ENGINE_WHISPERKIT}:openai_whisper-small_216MB",
                f"{ENGINE_MLX_AUDIO}:whisper-large-v3-turbo-4bit",
            }
        return {
            f"{ENGINE_SHERPA_ONNX}:sensevoice-small-int8",
            f"{ENGINE_FASTER_WHISPER}:base",
            f"{ENGINE_FASTER_WHISPER}:distil-small.en",
        }
    if preferred_engine == ENGINE_WHISPERKIT:
        return {
            f"{ENGINE_WHISPERKIT}:openai_whisper-base",
            f"{ENGINE_SHERPA_ONNX}:sensevoice-small-int8",
        }
    return {
        f"{ENGINE_SHERPA_ONNX}:sensevoice-small-int8",
        f"{ENGINE_FASTER_WHISPER}:tiny",
    }
