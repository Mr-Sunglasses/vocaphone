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
