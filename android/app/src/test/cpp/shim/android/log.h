/*
 * Just enough of the NDK's <android/log.h> for jni.c to compile on a desktop,
 * where the model tests load it into a plain JVM. Warnings and errors go to
 * stderr; the chatter below them only with VOCA_WHISPER_VERBOSE set.
 */
#pragma once

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

enum {
    ANDROID_LOG_DEBUG = 3,
    ANDROID_LOG_INFO = 4,
    ANDROID_LOG_WARN = 5,
    ANDROID_LOG_ERROR = 6,
};

static inline int __android_log_print(int priority, const char *tag, const char *format, ...) {
    if (priority < ANDROID_LOG_WARN && getenv("VOCA_WHISPER_VERBOSE") == NULL) return 0;
    va_list arguments;
    va_start(arguments, format);
    fprintf(stderr, "%s: ", tag);
    const int written = vfprintf(stderr, format, arguments);
    va_end(arguments);
    return written;
}
