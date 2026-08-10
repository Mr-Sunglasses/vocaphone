#include <jni.h>
#include <android/log.h>
#include "whisper.h"

#define TAG "VocaPhoneWhisper"
#define UNUSED(value) (void)(value)

JNIEXPORT jlong JNICALL
Java_com_vocahq_vocaphone_local_WhisperLib_00024Companion_initContext(
        JNIEnv *env, jobject thiz, jstring model_path) {
    UNUSED(thiz);
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

JNIEXPORT void JNICALL
Java_com_vocahq_vocaphone_local_WhisperLib_00024Companion_fullTranscribe(
        JNIEnv *env, jobject thiz, jlong context_ptr, jint num_threads,
        jfloatArray audio_data, jstring language_str) {
    UNUSED(thiz);
    struct whisper_context *context = (struct whisper_context *) context_ptr;
    jfloat *audio = (*env)->GetFloatArrayElements(env, audio_data, NULL);
    jsize length = (*env)->GetArrayLength(env, audio_data);
    const char *language = (*env)->GetStringUTFChars(env, language_str, NULL);

    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.print_realtime = false;
    params.print_progress = false;
    params.print_timestamps = false;
    params.print_special = false;
    params.translate = false;
    params.language = language;
    params.n_threads = num_threads;
    params.no_context = true;
    params.single_segment = false;

    whisper_reset_timings(context);
    whisper_full(context, params, audio, length);

    (*env)->ReleaseStringUTFChars(env, language_str, language);
    (*env)->ReleaseFloatArrayElements(env, audio_data, audio, JNI_ABORT);
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

JNIEXPORT jstring JNICALL
Java_com_vocahq_vocaphone_local_WhisperLib_00024Companion_getSystemInfo(
        JNIEnv *env, jobject thiz) {
    UNUSED(thiz);
    return (*env)->NewStringUTF(env, whisper_print_system_info());
}
