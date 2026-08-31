#ifndef WASMBOX_WASMTIME_SHIM_H
#define WASMBOX_WASMTIME_SHIM_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

enum wasmbox_wasmtime_state {
  WASMBOX_WASMTIME_STOPPED = 0,
  WASMBOX_WASMTIME_RUNNING = 1,
};

int wasmbox_wasmtime_runtime_available(
    const char *const *library_paths,
    size_t library_count,
    char *message,
    size_t message_capacity);

int wasmbox_wasmtime_start(
    const char *runtime_name,
    const char *module_path,
    const char *const *arguments,
    size_t argument_count,
    const char *const *environment_names,
    const char *const *environment_values,
    size_t environment_count,
    const char *const *preopen_host_paths,
    const char *const *preopen_guest_paths,
    const int *preopen_read_only,
    size_t preopen_count,
    const char *stdout_path,
    const char *stderr_path,
    char *message,
    size_t message_capacity);

int wasmbox_wasmtime_stop(
    const char *runtime_name,
    unsigned int timeout_milliseconds,
    char *message,
    size_t message_capacity);

int wasmbox_wasmtime_inspect(
    const char *runtime_name,
    int *state,
    int *exit_code,
    char *message,
    size_t message_capacity);

#ifdef __cplusplus
}
#endif

#endif
