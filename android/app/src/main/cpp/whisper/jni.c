#include <jni.h>
#include <android/log.h>
#include <stdbool.h>
#include <time.h>
#include "whisper.h"
#include "ggml-backend.h"

#define TAG "VocaPhoneWhisper"
#define UNUSED(value) (void)(value)

/**
 * whisper.cpp writes its own diagnostics to stderr, which Android discards, so a
 * native failure left nothing behind to read. Forwarding the library's log to
 * logcat is what makes one visible in a bug report.
 *
 * Everything below a warning goes to debug: loading a model alone prints dozens
 * of lines, which is worth having on demand and not worth spending a user's log
 * buffer on.
 */
static void forward_whisper_log(enum ggml_log_level level, const char *text, void *user_data) {
    UNUSED(user_data);
    const int priority = level == GGML_LOG_LEVEL_ERROR ? ANDROID_LOG_ERROR
            : level == GGML_LOG_LEVEL_WARN ? ANDROID_LOG_WARN
            : ANDROID_LOG_DEBUG;
    __android_log_print(priority, TAG, "%s", text);
}

/**
 * Registers one already-loaded ggml CPU backend, and reports whether it took.
 *
 * The caller loads the shared library through the Java loader first, because the
 * libraries live uncompressed inside the APK rather than as files on disk, and
 * only that loader can find them there. `ggml_backend_load` then resolves the
 * same soname to the copy already in the process.
 *
 * A backend built for instructions this CPU lacks is declined here, by ggml's
 * own feature check, before any of its code runs — so asking for the fastest
 * tier first and walking down costs nothing on a phone that cannot take it.
 */
JNIEXPORT jboolean JNICALL
Java_com_vocahq_vocaphone_local_WhisperLib_00024Companion_registerBackend(
        JNIEnv *env, jobject thiz, jstring soname_str) {
    UNUSED(thiz);
    whisper_log_set(forward_whisper_log, NULL);
    const char *soname = (*env)->GetStringUTFChars(env, soname_str, NULL);
    const bool registered = ggml_backend_load(soname) != NULL;
    __android_log_print(
            registered ? ANDROID_LOG_INFO : ANDROID_LOG_DEBUG, TAG,
            "%s %s", registered ? "Using CPU backend" : "Declined CPU backend", soname);
    (*env)->ReleaseStringUTFChars(env, soname_str, soname);
    return registered ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jlong JNICALL
Java_com_vocahq_vocaphone_local_WhisperLib_00024Companion_initContext(
        JNIEnv *env, jobject thiz, jstring model_path) {
    UNUSED(thiz);
    whisper_log_set(forward_whisper_log, NULL);
    // Without a backend ggml aborts the process rather than failing the call, so
    // this stops at a null context the caller already reports as a model that
    // would not load.
    if (ggml_backend_reg_count() == 0) {
        __android_log_print(ANDROID_LOG_ERROR, TAG, "No ggml CPU backend is registered");
        return 0;
    }
    const char *path = (*env)->GetStringUTFChars(env, model_path, NULL);
    __android_log_print(ANDROID_LOG_INFO, TAG, "Loading model from %s", path);
    struct whisper_context *context = whisper_init_from_file_with_params(
            path, whisper_context_default_params());
    (*env)->ReleaseStringUTFChars(env, model_path, path);
    return (jlong) context;
}

JNIEXPORT void JNICALL
Java_com_vocahq_vocaphone_local_WhisperLib_00024Companion_freeContext(
        JNIEnv *env, jobject thiz, jlong context_ptr) {
    UNUSED(env);
    UNUSED(thiz);
    if (context_ptr != 0) whisper_free((struct whisper_context *) context_ptr);
}

/** Returns whisper's own status: zero on success, negative on failure. */
JNIEXPORT jint JNICALL
Java_com_vocahq_vocaphone_local_WhisperLib_00024Companion_fullTranscribe(
        JNIEnv *env, jobject thiz, jlong context_ptr, jint num_threads,
        jfloatArray audio_data, jstring language_str, jint beam_size,
        jfloat temperature_increment, jint audio_context, jstring prompt_str) {
    UNUSED(thiz);
    struct whisper_context *context = (struct whisper_context *) context_ptr;
    jfloat *audio = (*env)->GetFloatArrayElements(env, audio_data, NULL);
    jsize length = (*env)->GetArrayLength(env, audio_data);
    const char *language = (*env)->GetStringUTFChars(env, language_str, NULL);
    const char *prompt = prompt_str == NULL
            ? NULL
            : (*env)->GetStringUTFChars(env, prompt_str, NULL);

    // Beam search is what the Accurate setting buys; every other setting decodes
    // greedily, which is roughly twice as fast for slightly worse text.
    struct whisper_full_params params = whisper_full_default_params(
            beam_size > 0 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY);
    if (beam_size > 0) {
        params.beam_search.beam_size = beam_size;
    }
    params.print_realtime = false;
    params.print_progress = false;
    params.print_timestamps = false;
    params.print_special = false;
    params.translate = false;
    params.language = language;
    params.n_threads = num_threads;
    params.no_context = true;
    // The client does not print timestamps, but the decoder must still be able
    // to predict their tokens: they are how Whisper cleanly stops after speech.
    // Suppressing them made short phrases repeat over the padded window.
    params.no_timestamps = false;
    params.single_segment = true;
    // whisper.cpp defaults greedy.best_of to five. That default is also used
    // for temperature-fallback passes, and it turns a rare retry into five
    // decoder passes on a phone. One candidate is enough for Fast/Balanced;
    // Accurate's explicit beam width remains the accuracy knob.
    params.greedy.best_of = 1;
    // Stops the decoder emitting the `[MUSIC]`-style annotations at the source,
    // rather than stripping them from the text afterwards where a marker the
    // sanitizer has not seen before gets through.
    params.suppress_nst = true;
    // Zero disables fallback. Balanced passes 1.0 for exactly one retry;
    // Accurate passes 0.5 for two. The upstream 0.2 default permits five full
    // decoder retries and caused the multi-second latency spikes seen on phones.
    params.temperature_inc = temperature_increment;
    // Crops the encoder to the window the caller sized for this recording, so a
    // short dictation stops paying for the thirty-second one whisper otherwise
    // pads it to. Zero leaves whisper's own default in place.
    params.audio_ctx = audio_context;

    __android_log_print(
            ANDROID_LOG_INFO, TAG,
            "Transcribing %d samples with %d threads, beam=%d, temperature_inc=%.1f, audio_ctx=%d",
            (int) length, (int) num_threads, (int) beam_size,
            temperature_increment, (int) audio_context);

    if (prompt != NULL && prompt[0] != '\0') {
        params.initial_prompt = prompt;
        // Without this the vocabulary reaches only the first 30-second window,
        // because whisper otherwise treats the prompt as rolling context that
        // each decoded window overwrites.
        params.carry_initial_prompt = true;
    }

    whisper_reset_timings(context);
    // Returned rather than discarded: a failed decode leaves zero segments, and
    // reading those produces an empty transcript that looks to the user like the
    // microphone heard nothing rather than like the model gave up.
    struct timespec elapsed_start;
    clock_gettime(CLOCK_MONOTONIC, &elapsed_start);
    const jint status = whisper_full(context, params, audio, length);
    struct timespec elapsed_end;
    clock_gettime(CLOCK_MONOTONIC, &elapsed_end);
    const long elapsed_ms =
            (elapsed_end.tv_sec - elapsed_start.tv_sec) * 1000L +
            (elapsed_end.tv_nsec - elapsed_start.tv_nsec) / 1000000L;
    __android_log_print(
            ANDROID_LOG_INFO, TAG,
            "Transcription finished in %ld ms (status=%d, segments=%d)",
            elapsed_ms, (int) status, whisper_full_n_segments(context));

    if (prompt != NULL) {
        (*env)->ReleaseStringUTFChars(env, prompt_str, prompt);
    }
    (*env)->ReleaseStringUTFChars(env, language_str, language);
    (*env)->ReleaseFloatArrayElements(env, audio_data, audio, JNI_ABORT);
    return status;
}

JNIEXPORT jint JNICALL
Java_com_vocahq_vocaphone_local_WhisperLib_00024Companion_getTextSegmentCount(
        JNIEnv *env, jobject thiz, jlong context_ptr) {
    UNUSED(env);
    UNUSED(thiz);
    return whisper_full_n_segments((struct whisper_context *) context_ptr);
}

JNIEXPORT jstring JNICALL
Java_com_vocahq_vocaphone_local_WhisperLib_00024Companion_getTextSegment(
        JNIEnv *env, jobject thiz, jlong context_ptr, jint index) {
    UNUSED(thiz);
    const char *text = whisper_full_get_segment_text(
            (struct whisper_context *) context_ptr, index);
    return (*env)->NewStringUTF(env, text == NULL ? "" : text);
}

/**
 * The language whisper actually decoded, which is the only place "auto" turns
 * into something a caller can act on. Empty when the model reported nothing.
 */
JNIEXPORT jstring JNICALL
Java_com_vocahq_vocaphone_local_WhisperLib_00024Companion_getDetectedLanguage(
        JNIEnv *env, jobject thiz, jlong context_ptr) {
    UNUSED(thiz);
    const int id = whisper_full_lang_id((struct whisper_context *) context_ptr);
    if (id < 0) return (*env)->NewStringUTF(env, "");
    const char *code = whisper_lang_str(id);
    return (*env)->NewStringUTF(env, code == NULL ? "" : code);
}

JNIEXPORT jstring JNICALL
Java_com_vocahq_vocaphone_local_WhisperLib_00024Companion_getSystemInfo(
        JNIEnv *env, jobject thiz) {
    UNUSED(thiz);
    return (*env)->NewStringUTF(env, whisper_print_system_info());
}
