# The app's whisper JNI library, built for this computer instead of a phone, so
# a plain JVM unit test can load it and decode real speech with a real model.
#
# Same sources as src/main/cpp/whisper: the pinned whisper.cpp submodule and the
# app's own jni.c, unchanged. What differs is only what a desktop lacks or does
# not need: <android/log.h> comes from shim/, liblog and libandroid are not
# linked, and ggml's CPU backend is compiled in rather than loaded per CPU tier.
#
#     cmake -S app/src/test/cpp -B build/host-whisper -DCMAKE_BUILD_TYPE=Release
#     cmake --build build/host-whisper
#
# `just model-test` does this and points the tests at the result.
cmake_minimum_required(VERSION 3.14)
project(vocaphone_whisper_host C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
get_filename_component(WHISPER_LIB_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../../third_party/whisper.cpp" ABSOLUTE)
get_filename_component(APP_JNI_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/../../main/cpp/whisper" ABSOLUTE)

find_package(JNI REQUIRED)

# One self-contained library, as System.loadLibrary("whisper") expects.
set(BUILD_SHARED_LIBS OFF)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE ON CACHE BOOL "" FORCE)
# The phone build does no GPU work, so neither does this one.
set(GGML_METAL OFF CACHE BOOL "" FORCE)
set(GGML_BLAS OFF CACHE BOOL "" FORCE)
add_subdirectory("${WHISPER_LIB_DIR}/ggml" ggml)

add_library(whisper SHARED "${WHISPER_LIB_DIR}/src/whisper.cpp" "${APP_JNI_DIR}/jni.c")
target_compile_definitions(whisper PRIVATE WHISPER_VERSION="host" GGML_USE_CPU)
target_include_directories(whisper PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/shim"
    "${WHISPER_LIB_DIR}/include"
    "${WHISPER_LIB_DIR}/src"
    "${WHISPER_LIB_DIR}/ggml/include"
    ${JNI_INCLUDE_DIRS}
)
target_link_libraries(whisper PRIVATE ggml)
