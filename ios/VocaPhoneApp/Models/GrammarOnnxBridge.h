#include <stdint.h>

/// The grammar tagger's ONNX Runtime session, behind three C calls.
///
/// ONNX Runtime arrives in the app with sherpa-onnx (the static
/// `onnxruntime-libs` 1.28.2 xcframework), so this compiles against those
/// headers and links that copy: there is no second runtime. See
/// `GrammarSession.swift`.
typedef void *VocaPhoneGrammarSession;

/// Returns NULL and writes a message into `error` on failure.
VocaPhoneGrammarSession VocaPhoneGrammarCreate(
    const char *model_path,
    int32_t threads,
    char *error,
    int32_t error_capacity
);

/// Runs `ids` (length `length`) and copies the logit rows at `rows` back to
/// back into `output`, which holds `output_capacity` floats. Returns the
/// number of labels per row, or a negative value with `error` filled in.
int32_t VocaPhoneGrammarRun(
    VocaPhoneGrammarSession session,
    const int64_t *ids,
    int32_t length,
    const int32_t *rows,
    int32_t row_count,
    float *output,
    int64_t output_capacity,
    char *error,
    int32_t error_capacity
);

void VocaPhoneGrammarRelease(VocaPhoneGrammarSession session);
