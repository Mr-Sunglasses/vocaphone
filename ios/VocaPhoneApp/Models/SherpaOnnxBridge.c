#include "SherpaOnnxBridge.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <SherpaOnnxC/sherpa-onnx/c-api/c-api.h>

struct VocaPhoneSherpaContext {
    const SherpaOnnxOfflineRecognizer *recognizer;
    /// Rebuild the transcript from its tokens instead of reading `text`.
    ///
    /// sherpa-onnx drops the word-boundary spaces when it joins tokens in a
    /// non-Latin script, so the icefall Korean Zipformer comes back as
    /// "지하철에서다리를벌리고앉지마라." although every token it emitted carries
    /// its own leading space. Concatenating the tokens verbatim is the text the
    /// model actually produced.
    int join_tokens;
};

static int copy_text(
    const char *text,
    char *output,
    int32_t output_capacity
) {
    if (output == NULL || output_capacity <= 0) {
        return VocaPhoneSherpaDecodeInvalidArgument;
    }
    if (text == NULL) text = "";
    int written = snprintf(output, (size_t)output_capacity, "%s", text);
    // snprintf reports what it *would* have written, so a return at or past the
    // capacity means the transcript was cut. Saying so is the point: a truncated
    // decode and an empty one are opposite failures, and only one is worth
    // retrying a smaller window for.
    if (written < 0) return VocaPhoneSherpaDecodeInvalidArgument;
    if (written >= output_capacity) return VocaPhoneSherpaDecodeOutputTruncated;
    return written;
}

/// Concatenates `result`'s tokens into `output`, dropping the leading space
/// the first word-initial token carries. Same return contract as `copy_text`.
static int copy_joined_tokens(
    const SherpaOnnxOfflineRecognizerResult *result,
    char *output,
    int32_t output_capacity
) {
    if (output == NULL || output_capacity <= 0) {
        return VocaPhoneSherpaDecodeInvalidArgument;
    }
    if (result->tokens_arr == NULL || result->count <= 0) {
        return copy_text(result->text, output, output_capacity);
    }
    size_t used = 0;
    output[0] = '\0';
    for (int32_t i = 0; i < result->count; i++) {
        const char *token = result->tokens_arr[i];
        if (token == NULL) continue;
        if (used == 0) {
            while (*token == ' ') token++;
        }
        size_t length = strlen(token);
        if (used + length >= (size_t)output_capacity) {
            return VocaPhoneSherpaDecodeOutputTruncated;
        }
        memcpy(output + used, token, length);
        used += length;
        output[used] = '\0';
    }
    while (used > 0 && output[used - 1] == ' ') output[--used] = '\0';
    return (int)used;
}

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
        // An icefall Zipformer transducer. Same three graphs as NeMo's, but
        // sherpa-onnx must not be told it is NeMo: an empty model type lets it
        // read the Zipformer metadata instead.
        case VocaPhoneSherpaZipformerTransducer:
            config.model_config.transducer.encoder = model1;
            config.model_config.transducer.decoder = model2;
            config.model_config.transducer.joiner = model3;
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
        // Moonshine v2 ships two graphs rather than four: the preprocessor is
        // folded into the encoder, and the cached and uncached decoders are one
        // merged graph. The other four fields stay NULL, which is how
        // sherpa-onnx tells the two layouts apart.
        case VocaPhoneSherpaMoonshineV2:
            config.model_config.moonshine.encoder = model1;
            config.model_config.moonshine.merged_decoder = model2;
            break;
        case VocaPhoneSherpaDolphinCtc:
            config.model_config.dolphin.model = model1;
            break;
        case VocaPhoneSherpaOmnilingualCtc:
            config.model_config.omnilingual.model = model1;
            break;
        case VocaPhoneSherpaCanary:
            config.model_config.canary.encoder = model1;
            config.model_config.canary.decoder = model2;
            config.model_config.canary.src_lang = language;
            // Equal source and target is transcription; differing them is what
            // Canary was trained for. An empty target means the caller asked
            // for no translation, or asked for one this model cannot do.
            config.model_config.canary.tgt_lang =
                target_language == NULL || target_language[0] == '\0'
                    ? language
                    : target_language;
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
    result->join_tokens = family == VocaPhoneSherpaZipformerTransducer;
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
        return VocaPhoneSherpaDecodeInvalidArgument;
    }
    const SherpaOnnxOfflineStream *stream =
        SherpaOnnxCreateOfflineStream(context->recognizer);
    if (stream == NULL) return VocaPhoneSherpaDecodeStreamUnavailable;

    SherpaOnnxAcceptWaveformOffline(
        stream, 16000, samples, sample_count);
    SherpaOnnxDecodeOfflineStream(context->recognizer, stream);
    const SherpaOnnxOfflineRecognizerResult *result =
        SherpaOnnxGetOfflineStreamResult(stream);
    int copied = result == NULL
        ? VocaPhoneSherpaDecodeResultMissing
        : context->join_tokens
            ? copy_joined_tokens(result, output, output_capacity)
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
