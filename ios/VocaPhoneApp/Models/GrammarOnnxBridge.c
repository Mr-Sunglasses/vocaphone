#include "GrammarOnnxBridge.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <onnxruntime/onnxruntime_c_api.h>

// The same calls, in the same order, as android/app/src/main/cpp/grammar/grammar_jni.c.

static const OrtApi *ort = NULL;
static OrtEnv *env = NULL;
static pthread_once_t once = PTHREAD_ONCE_INIT;

typedef struct {
    OrtSession *session;
    OrtMemoryInfo *memory;
} Grammar;

static void load_runtime(void) {
    const OrtApi *api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    if (!api) return;
    OrtEnv *created = NULL;
    OrtStatus *status = api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "vocaphone-grammar", &created);
    if (status) {
        api->ReleaseStatus(status);
        return;
    }
    ort = api;
    env = created;
}

static void write_error(char *error, int32_t capacity, const char *message) {
    if (error && capacity > 0) snprintf(error, (size_t) capacity, "%s", message ? message : "unknown error");
}

// Writes the message and returns 1 when status is an error; releases it either way.
static int failed(OrtStatus *status, char *error, int32_t capacity) {
    if (!status) return 0;
    write_error(error, capacity, ort->GetErrorMessage(status));
    ort->ReleaseStatus(status);
    return 1;
}

VocaPhoneGrammarSession VocaPhoneGrammarCreate(
    const char *model_path, int32_t threads, char *error, int32_t error_capacity) {
    pthread_once(&once, load_runtime);
    if (!ort) {
        write_error(error, error_capacity, "ONNX Runtime 1.28 is not available");
        return NULL;
    }
    OrtSessionOptions *options = NULL;
    if (failed(ort->CreateSessionOptions(&options), error, error_capacity)) return NULL;
    Grammar *grammar = calloc(1, sizeof(Grammar));
    int ok = grammar &&
        !failed(ort->SetIntraOpNumThreads(options, threads), error, error_capacity) &&
        !failed(ort->SetInterOpNumThreads(options, 1), error, error_capacity) &&
        !failed(ort->SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL), error, error_capacity) &&
        !failed(ort->CreateSession(env, model_path, options, &grammar->session), error, error_capacity) &&
        !failed(ort->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &grammar->memory),
                error, error_capacity);
    ort->ReleaseSessionOptions(options);
    if (!ok) {
        if (grammar) {
            if (grammar->session) ort->ReleaseSession(grammar->session);
            free(grammar);
        }
        return NULL;
    }
    return grammar;
}

int32_t VocaPhoneGrammarRun(
    VocaPhoneGrammarSession session,
    const int64_t *ids,
    int32_t length,
    const int32_t *rows,
    int32_t row_count,
    float *output,
    int64_t output_capacity,
    char *error,
    int32_t error_capacity) {
    Grammar *grammar = (Grammar *) session;
    if (!grammar || !ids || length <= 0 || !rows || !output) {
        write_error(error, error_capacity, "invalid argument");
        return -1;
    }
    int64_t *mask = malloc(sizeof(int64_t) * (size_t) length);
    if (!mask) {
        write_error(error, error_capacity, "out of memory");
        return -1;
    }
    for (int32_t i = 0; i < length; i++) mask[i] = 1;

    int64_t shape[2] = {1, length};
    OrtValue *inputs[2] = {NULL, NULL};
    OrtValue *result = NULL;
    const char *input_names[2] = {"ids", "mask"};
    const char *output_names[1] = {"logits"};
    int32_t labels = -1;

    if (failed(ort->CreateTensorWithDataAsOrtValue(grammar->memory, (void *) ids, sizeof(int64_t) * (size_t) length,
            shape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &inputs[0]), error, error_capacity)) goto done;
    if (failed(ort->CreateTensorWithDataAsOrtValue(grammar->memory, mask, sizeof(int64_t) * (size_t) length,
            shape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &inputs[1]), error, error_capacity)) goto done;
    if (failed(ort->Run(grammar->session, NULL, input_names, (const OrtValue *const *) inputs, 2,
            output_names, 1, &result), error, error_capacity)) goto done;

    OrtTensorTypeAndShapeInfo *info = NULL;
    if (failed(ort->GetTensorTypeAndShape(result, &info), error, error_capacity)) goto done;
    int64_t dims[3] = {0, 0, 0};
    size_t rank = 0;
    OrtStatus *status = ort->GetDimensionsCount(info, &rank);
    if (!status && rank == 3) status = ort->GetDimensions(info, dims, 3);
    ort->ReleaseTensorTypeAndShapeInfo(info);
    if (failed(status, error, error_capacity)) goto done;
    if (rank != 3 || dims[1] != length || (int64_t) row_count * dims[2] > output_capacity) {
        write_error(error, error_capacity, "unexpected logits shape");
        goto done;
    }
    float *logits = NULL;
    if (failed(ort->GetTensorMutableData(result, (void **) &logits), error, error_capacity)) goto done;
    for (int32_t r = 0; r < row_count; r++) {
        if (rows[r] < 0 || rows[r] >= length) {
            write_error(error, error_capacity, "row out of range");
            goto done;
        }
        memcpy(output + (size_t) r * (size_t) dims[2], logits + (size_t) rows[r] * (size_t) dims[2],
               sizeof(float) * (size_t) dims[2]);
    }
    labels = (int32_t) dims[2];

done:
    if (result) ort->ReleaseValue(result);
    if (inputs[0]) ort->ReleaseValue(inputs[0]);
    if (inputs[1]) ort->ReleaseValue(inputs[1]);
    free(mask);
    return labels;
}

void VocaPhoneGrammarRelease(VocaPhoneGrammarSession session) {
    Grammar *grammar = (Grammar *) session;
    if (!grammar) return;
    if (grammar->session) ort->ReleaseSession(grammar->session);
    if (grammar->memory) ort->ReleaseMemoryInfo(grammar->memory);
    free(grammar);
}
