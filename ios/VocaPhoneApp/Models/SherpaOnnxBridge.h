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

VocaPhoneSherpaRecognizer VocaPhoneSherpaCreate(
    int family,
    const char *model1,
    const char *model2,
    const char *model3,
    const char *model4,
    const char *tokens,
    const char *language,
    int32_t threads
);

int VocaPhoneSherpaDecode(
    VocaPhoneSherpaRecognizer recognizer,
    const float *samples,
    int32_t sample_count,
    char *output,
    int32_t output_capacity
);

void VocaPhoneSherpaDestroy(VocaPhoneSherpaRecognizer recognizer);
