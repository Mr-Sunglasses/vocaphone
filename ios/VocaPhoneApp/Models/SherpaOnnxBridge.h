#include <stdint.h>

typedef void *VocaPhoneSherpaRecognizer;

/// The order is kept in sync with SherpaFamily in LocalModelCatalog.swift.
enum VocaPhoneSherpaFamily {
    VocaPhoneSherpaNemoTransducer = 0,
    VocaPhoneSherpaSenseVoice = 1,
    VocaPhoneSherpaMoonshine = 2,
    VocaPhoneSherpaDolphinCtc = 3,
    VocaPhoneSherpaCanary = 4,
    VocaPhoneSherpaNemoCtc = 5,
    VocaPhoneSherpaParaformer = 6,
    VocaPhoneSherpaMoonshineV2 = 7,
};

/// `language` is the language being spoken, and `target_language` the one to
/// translate it into — empty to transcribe rather than translate. Canary is the
/// only family with a target at all; see `ModelTranslationSupport`.
///
/// `decoding_method` is one of sherpa-onnx's literals — "greedy_search" or
/// "modified_beam_search" — and `max_active_paths` is the beam width the latter
/// searches. Only the transducer families act on either.
VocaPhoneSherpaRecognizer VocaPhoneSherpaCreate(
    int family,
    const char *model1,
    const char *model2,
    const char *model3,
    const char *model4,
    const char *tokens,
    const char *language,
    const char *target_language,
    int32_t threads,
    const char *decoding_method,
    int32_t max_active_paths
);

/// What a decode did, for the negative half of `VocaPhoneSherpaDecode`.
///
/// A decode that produces no tokens is a *success* returning zero characters:
/// the model was asked and answered nothing, which for a pause is the right
/// answer and for speech is the failure the recovery ladder exists to retry.
/// Everything below is the engine failing to answer at all, and retrying one of
/// these decodes the same broken state again for the same result — so the
/// caller must tell them apart before it spends inference on a retry.
enum VocaPhoneSherpaDecodeStatus {
    /// A null or already-destroyed recognizer, or no samples to decode.
    VocaPhoneSherpaDecodeInvalidArgument = -1,
    /// sherpa-onnx would not create an offline stream for this recognizer.
    VocaPhoneSherpaDecodeStreamUnavailable = -2,
    /// The stream decoded but carried no result object.
    VocaPhoneSherpaDecodeResultMissing = -3,
    /// The transcript did not fit the caller's output buffer. Distinct from an
    /// empty answer in exactly the way that matters: text was produced and lost.
    VocaPhoneSherpaDecodeOutputTruncated = -4,
};

/// Returns the number of characters written to `output` — zero being a genuine
/// empty result — or one of `VocaPhoneSherpaDecodeStatus` on failure.
///
/// `language` receives the model's own language label when it reports one — of
/// the families VocaPhone ships, only SenseVoice does, as a `<|en|>`-style tag.
/// It is set to an empty string otherwise, and may be NULL if not wanted.
int VocaPhoneSherpaDecode(
    VocaPhoneSherpaRecognizer recognizer,
    const float *samples,
    int32_t sample_count,
    char *output,
    int32_t output_capacity,
    char *language,
    int32_t language_capacity
);

void VocaPhoneSherpaDestroy(VocaPhoneSherpaRecognizer recognizer);
