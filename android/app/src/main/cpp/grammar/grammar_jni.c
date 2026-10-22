// JNI bridge from GrammarSession.kt to the ONNX Runtime the full and x flavors
// already ship for sherpa-onnx (src/full/jniLibs/<abi>/libonnxruntime.so).
//
// Nothing links against that library: it is opened with dlopen and entered
// through OrtGetApiBase, the one symbol libsherpa-onnx-jni.so imports too, so
// this compiles for every ABI and simply reports "unavailable" where the
// library is absent (x86_64 emulators). The fdroid flavor does not build this
// file at all. onnxruntime_c_api.h is ONNX Runtime 1.28.0's own (MIT), taken
// from the archive pinned in src/full/jniLibs/README.md.

#include <dlfcn.h>
#include <jni.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#include "onnxruntime_c_api.h"

typedef const OrtApiBase *(*GetApiBase)(void);

static const OrtApi *ort = NULL;
static OrtEnv *env = NULL;
static pthread_mutex_t init_lock = PTHREAD_MUTEX_INITIALIZER;

typedef struct {
    OrtSession *session;
    OrtMemoryInfo *memory;
} Grammar;

static void throw_java(JNIEnv *jni, const char *message) {
    jclass type = (*jni)->FindClass(jni, "java/lang/IllegalStateException");
    if (type) (*jni)->ThrowNew(jni, type, message);
}

// Throws and returns 1 when status is an error; releases it either way.
static int failed(JNIEnv *jni, OrtStatus *status) {
    if (!status) return 0;
    throw_java(jni, ort->GetErrorMessage(status));
    ort->ReleaseStatus(status);
    return 1;
}

static int load_runtime(JNIEnv *jni) {
    pthread_mutex_lock(&init_lock);
    if (!ort) {
        void *library = dlopen("libonnxruntime.so", RTLD_NOW | RTLD_GLOBAL);
        GetApiBase base = library ? (GetApiBase) dlsym(library, "OrtGetApiBase") : NULL;
        const OrtApi *api = base ? base()->GetApi(ORT_API_VERSION) : NULL;
        if (api) {
            OrtEnv *created = NULL;
            OrtStatus *status = api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "vocaphone-grammar", &created);
            if (status) {
                api->ReleaseStatus(status);
            } else {
                ort = api;
                env = created;
            }
        }
    }
    pthread_mutex_unlock(&init_lock);
    if (!ort) throw_java(jni, "ONNX Runtime 1.28 is not available in this build");
    return ort != NULL;
}

JNIEXPORT jlong JNICALL
Java_com_vocahq_vocaphone_grammar_GrammarSession_nativeCreate(
    JNIEnv *jni, jclass type, jstring model_path, jint threads) {
    (void) type;
    if (!load_runtime(jni)) return 0;

    OrtSessionOptions *options = NULL;
    if (failed(jni, ort->CreateSessionOptions(&options))) return 0;
    Grammar *grammar = calloc(1, sizeof(Grammar));
    const char *path = (*jni)->GetStringUTFChars(jni, model_path, NULL);
    int ok = grammar && path &&
        !failed(jni, ort->SetIntraOpNumThreads(options, threads)) &&
        !failed(jni, ort->SetInterOpNumThreads(options, 1)) &&
        !failed(jni, ort->SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL)) &&
        !failed(jni, ort->CreateSession(env, path, options, &grammar->session)) &&
        !failed(jni, ort->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &grammar->memory));
    if (path) (*jni)->ReleaseStringUTFChars(jni, model_path, path);
    ort->ReleaseSessionOptions(options);
    if (!ok) {
        if (grammar) {
            if (grammar->session) ort->ReleaseSession(grammar->session);
            free(grammar);
        }
        return 0;
    }
    return (jlong) (intptr_t) grammar;
}

// Runs one sequence and returns only the logit rows at [rows], back to back:
// a sentence needs one row per word, and copying all T x 15000 would be the
// most expensive thing the stage did.
JNIEXPORT jfloatArray JNICALL
Java_com_vocahq_vocaphone_grammar_GrammarSession_nativeRun(
    JNIEnv *jni, jclass type, jlong handle, jlongArray ids, jintArray rows) {
    (void) type;
    Grammar *grammar = (Grammar *) (intptr_t) handle;
    if (!grammar) {
        throw_java(jni, "grammar session is closed");
        return NULL;
    }
    jsize length = (*jni)->GetArrayLength(jni, ids);
    jsize row_count = (*jni)->GetArrayLength(jni, rows);
    int64_t *tokens = malloc(sizeof(int64_t) * (size_t) length);
    int64_t *mask = malloc(sizeof(int64_t) * (size_t) length);
    jint *positions = malloc(sizeof(jint) * (size_t) (row_count > 0 ? row_count : 1));
    if (!tokens || !mask || !positions) {
        free(tokens);
        free(mask);
        free(positions);
        throw_java(jni, "out of memory");
        return NULL;
    }
    (*jni)->GetLongArrayRegion(jni, ids, 0, length, (jlong *) tokens);
    (*jni)->GetIntArrayRegion(jni, rows, 0, row_count, positions);
    for (jsize i = 0; i < length; i++) mask[i] = 1;

    int64_t shape[2] = {1, length};
    OrtValue *inputs[2] = {NULL, NULL};
    OrtValue *output = NULL;
    jfloatArray result = NULL;
    const char *input_names[2] = {"ids", "mask"};
    const char *output_names[1] = {"logits"};

    if (failed(jni, ort->CreateTensorWithDataAsOrtValue(grammar->memory, tokens, sizeof(int64_t) * length,
            shape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &inputs[0]))) goto done;
    if (failed(jni, ort->CreateTensorWithDataAsOrtValue(grammar->memory, mask, sizeof(int64_t) * length,
            shape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &inputs[1]))) goto done;
    if (failed(jni, ort->Run(grammar->session, NULL, input_names, (const OrtValue *const *) inputs, 2,
            output_names, 1, &output))) goto done;

    OrtTensorTypeAndShapeInfo *info = NULL;
    if (failed(jni, ort->GetTensorTypeAndShape(output, &info))) goto done;
    int64_t dims[3] = {0, 0, 0};
    size_t rank = 0;
    OrtStatus *status = ort->GetDimensionsCount(info, &rank);
    if (!status && rank == 3) status = ort->GetDimensions(info, dims, 3);
    ort->ReleaseTensorTypeAndShapeInfo(info);
    if (failed(jni, status)) goto done;
    if (rank != 3 || dims[1] != length) {
        throw_java(jni, "unexpected logits shape");
        goto done;
    }
    float *logits = NULL;
    if (failed(jni, ort->GetTensorMutableData(output, (void **) &logits))) goto done;
    jsize labels = (jsize) dims[2];
    result = (*jni)->NewFloatArray(jni, row_count * labels);
    if (!result) goto done;
    for (jsize r = 0; r < row_count; r++) {
        if (positions[r] < 0 || positions[r] >= length) {
            throw_java(jni, "row out of range");
            result = NULL;
            goto done;
        }
        (*jni)->SetFloatArrayRegion(jni, result, r * labels, labels, logits + (size_t) positions[r] * labels);
    }

done:
    if (output) ort->ReleaseValue(output);
    if (inputs[0]) ort->ReleaseValue(inputs[0]);
    if (inputs[1]) ort->ReleaseValue(inputs[1]);
    free(tokens);
    free(mask);
    free(positions);
    return result;
}

JNIEXPORT void JNICALL
Java_com_vocahq_vocaphone_grammar_GrammarSession_nativeRelease(JNIEnv *jni, jclass type, jlong handle) {
    (void) jni;
    (void) type;
    Grammar *grammar = (Grammar *) (intptr_t) handle;
    if (!grammar) return;
    if (grammar->session) ort->ReleaseSession(grammar->session);
    if (grammar->memory) ort->ReleaseMemoryInfo(grammar->memory);
    free(grammar);
}
