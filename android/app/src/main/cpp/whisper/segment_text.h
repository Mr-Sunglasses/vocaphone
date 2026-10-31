#ifndef VOCAPHONE_SEGMENT_TEXT_H
#define VOCAPHONE_SEGMENT_TEXT_H

#include <jni.h>
#include <string.h>

/** The text of segment `index` of `source`, or NULL for none. */
typedef const char *(*segment_text_at)(void *source, int index);

/**
 * Every segment's text, joined, as the raw bytes whisper produced.
 *
 * Bytes rather than a string, because whisper splits segments between tokens,
 * not characters. A Devanagari or CJK character is several UTF-8 bytes and
 * often several tokens, so one segment can end halfway through a character
 * that the next segment finishes. Each half is invalid UTF-8, and
 * NewStringUTF on it is undefined: CheckJNI aborts the process, and a desktop
 * JVM decodes the bytes as Latin-1 ("à¤"). Joined first, the halves are one
 * character again, and the caller decodes the whole as UTF-8.
 *
 * Kept apart from jni.c so the host test library can run it on segments it
 * makes up, without a model (src/test/cpp/segment_text_test.c).
 */
static jbyteArray joined_segment_text(JNIEnv *env, void *source, int segments, segment_text_at text_at) {
    size_t length = 0;
    for (int index = 0; index < segments; index++) {
        const char *text = text_at(source, index);
        if (text != NULL) length += strlen(text);
    }
    jbyteArray bytes = (*env)->NewByteArray(env, (jsize) length);
    if (bytes == NULL) return NULL;
    jsize offset = 0;
    for (int index = 0; index < segments; index++) {
        const char *text = text_at(source, index);
        if (text == NULL) continue;
        const jsize count = (jsize) strlen(text);
        (*env)->SetByteArrayRegion(env, bytes, offset, count, (const jbyte *) text);
        offset += count;
    }
    return bytes;
}

#endif
