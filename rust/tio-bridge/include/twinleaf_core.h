/* SPDX-License-Identifier: Apache-2.0 */

#ifndef TWINLEAF_CORE_H
#define TWINLEAF_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TwinleafRuntime TwinleafRuntime;

/* kind: 0 = JSON event, 1 = binary plot frame, 2 = binary typed event. */
typedef void (*TwinleafEventCallback)(
    uint32_t kind,
    const uint8_t *data,
    size_t len,
    uintptr_t context
);

/* tag: 1 = bool, 2 = string, 3 = double, 4 = int, 5 = uint;
   any other value means no argument. Only the field matching the tag
   is read. */
typedef struct TwinleafRpcArg {
    uint8_t tag;
    uint8_t bool_value;
    int64_t int_value;
    uint64_t uint_value;
    double double_value;
    const char *string_value;
} TwinleafRpcArg;

TwinleafRuntime *twinleaf_runtime_create(TwinleafEventCallback callback, uintptr_t context);
void twinleaf_runtime_destroy(TwinleafRuntime *runtime);
void twinleaf_runtime_list_devices(TwinleafRuntime *runtime, uint8_t include_all);
void twinleaf_runtime_connect(
    TwinleafRuntime *runtime,
    const char *url,
    const char *route,
    const char *log_path
);
void twinleaf_runtime_open_log(TwinleafRuntime *runtime, const char *path);
/* format: 1 = HDF5, any other value = CSV. */
void twinleaf_runtime_export_log(
    TwinleafRuntime *runtime,
    const char *request_id,
    const char *source_path,
    const char *output_path,
    uint8_t format
);
void twinleaf_runtime_disconnect(TwinleafRuntime *runtime);
void twinleaf_runtime_check_upgrade(TwinleafRuntime *runtime);
void twinleaf_runtime_perform_upgrade(TwinleafRuntime *runtime, const char *route);
void twinleaf_runtime_set_logging(
    TwinleafRuntime *runtime,
    uint8_t enabled,
    const char *log_path
);
void twinleaf_runtime_set_playback(TwinleafRuntime *runtime, double position);
void twinleaf_runtime_copy_view_data(
    TwinleafRuntime *runtime,
    const char *request_id,
    size_t pane_id,
    uint8_t has_viewport_end,
    double viewport_end
);
/* json is a serialized ClientCommand (see tio-bridge). Returns false if the
   pointer is null or the payload does not parse as a known command. */
bool twinleaf_runtime_send_command_json(TwinleafRuntime *runtime, const char *json);
void twinleaf_runtime_call_rpc(
    TwinleafRuntime *runtime,
    const char *request_id,
    const char *route,
    const char *name,
    const char *arg_json
);
void twinleaf_runtime_call_rpc_value(
    TwinleafRuntime *runtime,
    const char *request_id,
    const char *route,
    const char *name,
    const TwinleafRpcArg *arg
);

#ifdef __cplusplus
}
#endif

#endif
