#include "ggml.h"

int common_log_verbosity_thold = 0;

struct common_log * common_log_main() { return nullptr; }
void common_log_add(struct common_log * log, enum ggml_log_level level, const char * fmt, ...) {}
void common_log_default_callback(enum ggml_log_level level, const char * text, void * user_data) {}
void common_log_set_prefix(struct common_log * log, bool prefix) {}
void common_log_set_timestamps(struct common_log * log, bool timestamps) {}

// Stubs for b9222 symbols defined upstream in fit.cpp, which we cannot compile
// because it pulls in llama.cpp's private src/ headers. These are advisory
// memory-fit helpers; returning ERROR / no-op is safe — callers fall back to
// their own params.
#include "fit.h"
extern "C" {
struct llama_model_params;
struct llama_context_params;
struct llama_model_tensor_buft_override;
struct llama_context;
}
enum common_params_fit_status common_fit_params(
    const char *, struct llama_model_params *, struct llama_context_params *,
    float *, struct llama_model_tensor_buft_override *, unsigned long *,
    unsigned int, enum ggml_log_level
) {
    return COMMON_PARAMS_FIT_STATUS_ERROR;
}
void common_memory_breakdown_print(const struct llama_context *) {}
