/* SPDX-License-Identifier: Apache-2.0 */

#ifndef TWINLEAF_CORE_H
#define TWINLEAF_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TwinleafRuntime TwinleafRuntime;

typedef void (*TwinleafEventCallback)(
    uint32_t kind,
    const uint8_t *data,
    size_t len,
    uintptr_t context
);

TwinleafRuntime *twinleaf_runtime_create(TwinleafEventCallback callback, uintptr_t context);
void twinleaf_runtime_destroy(TwinleafRuntime *runtime);
void twinleaf_runtime_list_devices(TwinleafRuntime *runtime, uint8_t include_all);
void twinleaf_runtime_connect(
    TwinleafRuntime *runtime,
    const char *url,
    const char *route,
    const char *log_path
);
void twinleaf_runtime_set_logging(
    TwinleafRuntime *runtime,
    uint8_t enabled,
    const char *log_path
);
void twinleaf_runtime_open_log(TwinleafRuntime *runtime, const char *path);
void twinleaf_runtime_export_log(
    TwinleafRuntime *runtime,
    const char *request_id,
    const char *source_path,
    const char *output_path,
    uint8_t format
);
void twinleaf_runtime_disconnect(TwinleafRuntime *runtime);
void twinleaf_runtime_set_playback(TwinleafRuntime *runtime, double position);
void twinleaf_runtime_copy_view_data(
    TwinleafRuntime *runtime,
    const char *request_id,
    size_t pane_id,
    uint8_t has_viewport_end,
    double viewport_end
);
void twinleaf_runtime_set_plot_panes(
    TwinleafRuntime *runtime,
    const size_t *pane_ids,
    const uint8_t *modes,
    const double *window_seconds,
    const size_t *resolution_multipliers,
    const size_t *plot_width_pixels,
    const uint8_t *decimation_methods,
    const uint8_t *detrends,
    const uint8_t *fft_log_xs,
    const uint8_t *fft_log_ys,
    size_t pane_count,
    const size_t *column_pane_ids,
    const char *const *routes,
    const uint8_t *stream_ids,
    const size_t *column_indices,
    size_t column_count
);
void twinleaf_runtime_set_view(
    TwinleafRuntime *runtime,
    uint8_t mode,
    double window_seconds,
    size_t resolution_multiplier,
    size_t plot_width_pixels,
    uint8_t decimation_method,
    uint8_t detrend,
    uint8_t fft_log_x,
    uint8_t fft_log_y
);
void twinleaf_runtime_call_rpc(
    TwinleafRuntime *runtime,
    const char *request_id,
    const char *route,
    const char *name,
    const char *arg_json
);

#ifdef __cplusplus
}
#endif

#endif
