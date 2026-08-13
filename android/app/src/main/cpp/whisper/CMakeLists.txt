cmake_minimum_required(VERSION 3.10)

project(vocaphone_whisper)

set(CMAKE_CXX_STANDARD 17)
set(WHISPER_LIB_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../third_party/whisper.cpp)

if(NOT EXISTS "${WHISPER_LIB_DIR}/src/whisper.cpp")
    message(FATAL_ERROR "whisper.cpp source is missing from android/third_party/whisper.cpp")
endif()

file(READ "${WHISPER_LIB_DIR}/CMakeLists.txt" WHISPER_CMAKE)
string(REGEX MATCH "project\\(\\\"whisper\\.cpp\\\" VERSION ([0-9]+\\.[0-9]+\\.[0-9]+)" VERSION_MATCH "${WHISPER_CMAKE}")
if(CMAKE_MATCH_1)
    set(WHISPER_VERSION ${CMAKE_MATCH_1})
else()
    set(WHISPER_VERSION "unknown")
endif()

set(SOURCE_FILES
    ${WHISPER_LIB_DIR}/src/whisper.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/jni.c
)

find_library(LOG_LIB log)
include(FetchContent)

# One library, built for the architecture baseline every device of an ABI is
# guaranteed to have.
#
# There used to be a `whisper_v8fp16_va` variant tried first at load time, with a
# plain `whisper` behind it as a fallback. The fallback was never real: both
# linked the same `libggml-cpu.so`, so whichever wrapper loaded, the kernels that
# do the work were the same ones — and once those carried `-march=armv8.2-a+fp16`
# they emitted `fmla v.8h` and friends, which are undefined on an ARMv8.0 CPU.
# Loading a shared library does not check the instruction set, so an older arm64
# phone linked successfully and then died on SIGILL partway through a dictation,
# with no way to fall back.
#
# Dropping the flag measured ~1% on a Snapdragon 845 (median 1437 ms against
# 1463 ms for a two-second dictation), because ggml's hot paths are integer NEON
# and only fifteen fp16 arithmetic instructions existed in the whole library.
# That is not a trade worth a crash on hardware we cannot test.
function(build_whisper target_name)
    add_library(${target_name} SHARED ${SOURCE_FILES})
    target_compile_definitions(${target_name} PUBLIC GGML_USE_CPU)
    target_compile_definitions(${target_name} PRIVATE WHISPER_VERSION="${WHISPER_VERSION}")

    if(NOT CMAKE_BUILD_TYPE STREQUAL "Debug")
        target_compile_options(${target_name} PRIVATE -O3 -fvisibility=hidden -fvisibility-inlines-hidden)
        target_compile_options(${target_name} PRIVATE -ffunction-sections -fdata-sections)
        target_link_options(${target_name} PRIVATE -Wl,--gc-sections -Wl,--exclude-libs,ALL -flto)
    endif()

    # arm64 ships one ggml CPU backend per instruction-set tier instead of a
    # single baseline one. ggml compiles each tier's feature check without the
    # tier's own architecture flags, so an unsupported backend scores zero and is
    # declined rather than executed — the runtime dispatch the old library-name
    # guessing only pretended to do. Every other ABI keeps the built-in backend.
    if(ANDROID_ABI STREQUAL "arm64-v8a")
        set(GGML_BACKEND_DL ON CACHE BOOL "" FORCE)
        set(GGML_CPU_ALL_VARIANTS ON CACHE BOOL "" FORCE)
        # The variants are CMake MODULE libraries, which Android Gradle only
        # packages from the directory it already collects the shared ones from.
        set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_LIBRARY_OUTPUT_DIRECTORY})
    endif()

    FetchContent_Declare(ggml SOURCE_DIR ${WHISPER_LIB_DIR}/ggml)
    FetchContent_MakeAvailable(ggml)
    target_include_directories(${target_name} PRIVATE
        ${WHISPER_LIB_DIR}
        ${WHISPER_LIB_DIR}/src
        ${WHISPER_LIB_DIR}/include
        ${WHISPER_LIB_DIR}/ggml/include
        ${WHISPER_LIB_DIR}/ggml/src
        ${WHISPER_LIB_DIR}/ggml/src/ggml-cpu
    )
    target_link_libraries(${target_name} ${LOG_LIB} android ggml)
endfunction()

build_whisper(whisper)
