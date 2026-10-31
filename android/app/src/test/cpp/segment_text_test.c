/*
 * WhisperSegmentTextTest's way into joined_segment_text: segments it makes up,
 * as byte arrays, joined by the same code the app runs on whisper's segments.
 * Only the host test library has it; the phone's does not.
 */
#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include "segment_text.h"

struct segments {
    char **texts;
};

static const char *segment_at(void *source, int index) {
    return ((struct segments *) source)->texts[index];
}

JNIEXPORT jbyteArray JNICALL
Java_com_vocahq_vocaphone_local_WhisperSegmentTextTest_00024Companion_join(
        JNIEnv *env, jobject thiz, jobjectArray arrays) {
    (void) thiz;
    const jsize count = (*env)->GetArrayLength(env, arrays);
    struct segments segments = { calloc((size_t) count, sizeof(char *)) };
    for (jsize index = 0; index < count; index++) {
        jbyteArray array = (*env)->GetObjectArrayElement(env, arrays, index);
        const jsize length = (*env)->GetArrayLength(env, array);
        segments.texts[index] = calloc((size_t) length + 1, 1);
        (*env)->GetByteArrayRegion(env, array, 0, length, (jbyte *) segments.texts[index]);
        (*env)->DeleteLocalRef(env, array);
    }
    jbyteArray joined = joined_segment_text(env, &segments, count, segment_at);
    for (jsize index = 0; index < count; index++) free(segments.texts[index]);
    free(segments.texts);
    return joined;
}
