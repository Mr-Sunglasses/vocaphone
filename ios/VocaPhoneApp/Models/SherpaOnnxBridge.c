#include "SherpaOnnxBridge.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sherpa-onnx/c-api/c-api.h"

struct VocaPhoneSherpaContext {
    const SherpaOnnxOfflineRecognizer *recognizer;
};

static int copy_text(
    const char *text,
    char *output,
    int32_t output_capacity
) {
    if (output == NULL || output_capacity <= 0) return -1;
    if (text == NULL) text = "";
    int written = snprintf(output, (size_t)output_capacity, "%s", text);
    return written < 0 || written >= output_capacity ? -1 : written;
}

VocaPhoneSherpaRecognizer VocaPhoneSherpaCreate(
    int family,
    const char *model1,
    const char *model2,
    const char *model3,
    const char *model4,
    const char *tokens,
    const char *language,
    int32_t threads,
    const char *decoding_method,
    int32_t max_active_paths
) {
    SherpaOnnxOfflineRecognizerConfig config;
    memset(&config, 0, sizeof(config));
    config.feat_config.sample_rate = 16000;
    config.feat_config.feature_dim = 80;
    config.model_config.tokens = tokens;
    config.model_config.num_threads = threads;
    config.model_config.provider = "cpu";
    config.decoding_method = decoding_method == NULL || decoding_method[0] == '\0'
        ? "greedy_search"
        : decoding_method;
    config.max_active_paths = max_active_paths > 0 ? max_active_paths : 4;
    config.hotwords_score = 1.5f;

    switch (family) {
        case VocaPhoneSherpaNemoTransducer:
            config.model_config.transducer.encoder = model1;
            config.model_config.transducer.decoder = model2;
            config.model_config.transducer.joiner = model3;
            config.model_config.model_type = "nemo_transducer";
            break;
        case VocaPhoneSherpaSenseVoice:
            config.model_config.sense_voice.model = model1;
            config.model_config.sense_voice.language = language;
            config.model_config.sense_voice.use_itn = 1;
            break;
        case VocaPhoneSherpaMoonshine:
            config.model_config.moonshine.preprocessor = model1;
            config.model_config.moonshine.encoder = model2;
            config.model_config.moonshine.uncached_decoder = model3;
            config.model_config.moonshine.cached_decoder = model4;
            break;
        case VocaPhoneSherpaDolphinCtc:
            config.model_config.dolphin.model = model1;
            break;
        case VocaPhoneSherpaCanary:
            config.model_config.canary.encoder = model1;
            config.model_config.canary.decoder = model2;
            config.model_config.canary.src_lang = language;
            config.model_config.canary.tgt_lang = language;
            config.model_config.canary.use_pnc = 1;
            break;
        case VocaPhoneSherpaNemoCtc:
            config.model_config.nemo_ctc.model = model1;
            break;
        case VocaPhoneSherpaParaformer:
            config.model_config.paraformer.model = model1;
            break;
        default:
            return NULL;
    }

    const SherpaOnnxOfflineRecognizer *native =
        SherpaOnnxCreateOfflineRecognizer(&config);
    if (native == NULL) return NULL;

    struct VocaPhoneSherpaContext *result =
        (struct VocaPhoneSherpaContext *)calloc(1, sizeof(*result));
    if (result == NULL) {
        SherpaOnnxDestroyOfflineRecognizer(native);
        return NULL;
    }
    result->recognizer = native;
    return (VocaPhoneSherpaRecognizer)result;
}

int VocaPhoneSherpaDecode(
    VocaPhoneSherpaRecognizer recognizer,
    const float *samples,
    int32_t sample_count,
    char *output,
    int32_t output_capacity,
    char *language,
    int32_t language_capacity
) {
    // Emptied up front so a caller never reads a stale or uninitialised buffer
    // on any of the paths below that return without decoding.
    if (language != NULL && language_capacity > 0) language[0] = '\0';

    struct VocaPhoneSherpaContext *context =
        (struct VocaPhoneSherpaContext *)recognizer;
    if (context == NULL || context->recognizer == NULL ||
        samples == NULL || sample_count <= 0) {
        return -1;
    }
    const SherpaOnnxOfflineStream *stream =
        SherpaOnnxCreateOfflineStream(context->recognizer);
    if (stream == NULL) return -1;

    SherpaOnnxAcceptWaveformOffline(
        stream, 16000, samples, sample_count);
    SherpaOnnxDecodeOfflineStream(context->recognizer, stream);
    const SherpaOnnxOfflineRecognizerResult *result =
        SherpaOnnxGetOfflineStreamResult(stream);
    int copied = result == NULL
        ? -1
        : copy_text(result->text, output, output_capacity);
    if (result != NULL) {
        // Optional in the struct and left null by every family except
        // SenseVoice, so it is never dereferenced without checking.
        if (language != NULL && language_capacity > 0 && result->lang != NULL) {
            copy_text(result->lang, language, language_capacity);
        }
        SherpaOnnxDestroyOfflineRecognizerResult(result);
    }
    SherpaOnnxDestroyOfflineStream(stream);
    return copied;
}

void VocaPhoneSherpaDestroy(VocaPhoneSherpaRecognizer recognizer) {
    if (recognizer == NULL) return;
    struct VocaPhoneSherpaContext *context =
        (struct VocaPhoneSherpaContext *)recognizer;
    if (context->recognizer != NULL) {
        SherpaOnnxDestroyOfflineRecognizer(context->recognizer);
    }
    free(context);
}
