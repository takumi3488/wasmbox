#include "WasmtimeShim.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Opaque C API types. The shim intentionally links Wasmtime at runtime so the
 * app can remain installable when the optional Wasmtime C API is absent. */
typedef struct wasm_config wasm_config_t;
typedef struct wasm_engine wasm_engine_t;
typedef struct wasm_store wasm_store_t;
typedef struct wasmtime_store wasmtime_store_t;
typedef struct wasmtime_context wasmtime_context_t;
typedef struct wasi_config wasi_config_t;
typedef struct wasmtime_module wasmtime_module_t;
typedef struct wasmtime_linker wasmtime_linker_t;
typedef struct wasmtime_error wasmtime_error_t;
typedef struct wasm_trap wasm_trap_t;

typedef struct {
  size_t size;
  char *data;
} wasm_byte_vec_t;

typedef struct {
  uint64_t store_id;
  void *private_data;
} wasmtime_func_t;

typedef struct {
  uint64_t store_id;
  size_t private_data;
} wasmtime_instance_t;

typedef union {
  wasmtime_func_t func;
  unsigned char opaque[16];
} wasmtime_extern_union_t;

typedef struct {
  uint8_t kind;
  uint8_t padding[7];
  wasmtime_extern_union_t of;
} wasmtime_extern_t;

typedef struct WasmtimeApi WasmtimeApi;
typedef struct WasmtimeRun WasmtimeRun;

typedef wasm_engine_t *(*fn_wasm_engine_new_with_config)(wasm_config_t *);
typedef void (*fn_wasm_engine_delete)(wasm_engine_t *);
typedef wasm_config_t *(*fn_wasm_config_new)(void);
typedef void (*fn_wasm_config_delete)(wasm_config_t *);
typedef void (*fn_wasmtime_config_epoch_interruption_set)(wasm_config_t *, bool);
typedef void (*fn_wasi_config_delete)(wasi_config_t *);
typedef wasmtime_store_t *(*fn_wasmtime_store_new)(
    wasm_engine_t *, void *, void (*)(void *));
typedef wasmtime_context_t *(*fn_wasmtime_store_context)(wasmtime_store_t *);
typedef void (*fn_wasmtime_store_delete)(wasmtime_store_t *);
typedef void (*fn_wasmtime_context_set_epoch_deadline)(wasmtime_context_t *, uint64_t);
typedef void (*fn_wasmtime_engine_increment_epoch)(wasm_engine_t *);
typedef wasi_config_t *(*fn_wasi_config_new)(void);
typedef bool (*fn_wasi_config_set_argv)(
    wasi_config_t *, size_t, const char **);
typedef bool (*fn_wasi_config_set_env)(
    wasi_config_t *, size_t, const char **, const char **);
typedef bool (*fn_wasi_config_set_stdout_file)(wasi_config_t *, const char *);
typedef bool (*fn_wasi_config_set_stderr_file)(wasi_config_t *, const char *);
typedef bool (*fn_wasi_config_preopen_dir)(
    wasi_config_t *, const char *, const char *, size_t, size_t);
typedef wasmtime_error_t *(*fn_wasmtime_context_set_wasi)(
    wasmtime_context_t *, wasi_config_t *);
typedef wasmtime_linker_t *(*fn_wasmtime_linker_new)(wasm_engine_t *);
typedef void (*fn_wasmtime_linker_delete)(wasmtime_linker_t *);
typedef wasmtime_error_t *(*fn_wasmtime_linker_define_wasi)(wasmtime_linker_t *);
typedef wasmtime_error_t *(*fn_wasmtime_module_new)(
    wasm_engine_t *, const uint8_t *, size_t, wasmtime_module_t **);
typedef void (*fn_wasmtime_module_delete)(wasmtime_module_t *);
typedef wasmtime_error_t *(*fn_wasmtime_linker_instantiate)(
    const wasmtime_linker_t *,
    wasmtime_context_t *,
    const wasmtime_module_t *,
    wasmtime_instance_t *,
    wasm_trap_t **);
typedef bool (*fn_wasmtime_instance_export_get)(
    wasmtime_context_t *,
    const wasmtime_instance_t *,
    const char *,
    size_t,
    wasmtime_extern_t *);
typedef wasmtime_error_t *(*fn_wasmtime_func_call)(
    wasmtime_context_t *,
    const wasmtime_func_t *,
    const void *,
    size_t,
    void *,
    size_t,
    wasm_trap_t **);
typedef void (*fn_wasmtime_extern_delete)(wasmtime_extern_t *);
typedef void (*fn_wasmtime_error_delete)(wasmtime_error_t *);
typedef void (*fn_wasmtime_error_message)(
    const wasmtime_error_t *, wasm_byte_vec_t *);
typedef bool (*fn_wasmtime_error_exit_status)(const wasmtime_error_t *, int *);
typedef void (*fn_wasm_trap_delete)(wasm_trap_t *);
typedef void (*fn_wasm_byte_vec_delete)(wasm_byte_vec_t *);

struct WasmtimeApi {
  void *handle;
  fn_wasm_engine_new_with_config wasm_engine_new_with_config;
  fn_wasm_engine_delete wasm_engine_delete;
  fn_wasm_config_new wasm_config_new;
  fn_wasm_config_delete wasm_config_delete;
  fn_wasmtime_config_epoch_interruption_set wasmtime_config_epoch_interruption_set;
  fn_wasi_config_delete wasi_config_delete;
  fn_wasmtime_store_new wasmtime_store_new;
  fn_wasmtime_store_context wasmtime_store_context;
  fn_wasmtime_store_delete wasmtime_store_delete;
  fn_wasmtime_context_set_epoch_deadline wasmtime_context_set_epoch_deadline;
  fn_wasmtime_engine_increment_epoch wasmtime_engine_increment_epoch;
  fn_wasi_config_new wasi_config_new;
  fn_wasi_config_set_argv wasi_config_set_argv;
  fn_wasi_config_set_env wasi_config_set_env;
  fn_wasi_config_set_stdout_file wasi_config_set_stdout_file;
  fn_wasi_config_set_stderr_file wasi_config_set_stderr_file;
  fn_wasi_config_preopen_dir wasi_config_preopen_dir;
  fn_wasmtime_context_set_wasi wasmtime_context_set_wasi;
  fn_wasmtime_linker_new wasmtime_linker_new;
  fn_wasmtime_linker_delete wasmtime_linker_delete;
  fn_wasmtime_linker_define_wasi wasmtime_linker_define_wasi;
  fn_wasmtime_module_new wasmtime_module_new;
  fn_wasmtime_module_delete wasmtime_module_delete;
  fn_wasmtime_linker_instantiate wasmtime_linker_instantiate;
  fn_wasmtime_instance_export_get wasmtime_instance_export_get;
  fn_wasmtime_func_call wasmtime_func_call;
  fn_wasmtime_extern_delete wasmtime_extern_delete;
  fn_wasmtime_error_delete wasmtime_error_delete;
  fn_wasmtime_error_message wasmtime_error_message;
  fn_wasmtime_error_exit_status wasmtime_error_exit_status;
  fn_wasm_trap_delete wasm_trap_delete;
  fn_wasm_byte_vec_delete wasm_byte_vec_delete;
};

static pthread_mutex_t api_mutex = PTHREAD_MUTEX_INITIALIZER;
static WasmtimeApi api;
static bool api_loaded = false;

static pthread_mutex_t runs_mutex = PTHREAD_MUTEX_INITIALIZER;
static WasmtimeRun *runs = NULL;

struct WasmtimeRun {
  char *name;
  char *module_path;
  char **arguments;
  size_t argument_count;
  char **environment_names;
  char **environment_values;
  size_t environment_count;
  char **preopen_host_paths;
  char **preopen_guest_paths;
  int *preopen_read_only;
  size_t preopen_count;
  char *stdout_path;
  char *stderr_path;
  pthread_t thread;
  bool thread_started;
  bool stop_requested;
  int state;
  int exit_code;
  char message[1024];
  wasm_engine_t *engine;
  WasmtimeRun *next;
};

static void set_message(char *message, size_t capacity, const char *value) {
  if (message == NULL || capacity == 0) return;
  if (value == NULL) value = "";
  snprintf(message, capacity, "%s", value);
}

static char *copy_string(const char *value) {
  if (value == NULL) return NULL;
  size_t length = strlen(value);
  char *copy = (char *)malloc(length + 1);
  if (copy == NULL) return NULL;
  memcpy(copy, value, length + 1);
  return copy;
}

static char **copy_string_array(
    const char *const *values,
    size_t count) {
  if (count == 0) return NULL;
  if (values == NULL) return NULL;
  char **copies = (char **)calloc(count, sizeof(char *));
  if (copies == NULL) return NULL;
  for (size_t index = 0; index < count; index++) {
    copies[index] = copy_string(values[index]);
    if (copies[index] == NULL) {
      for (size_t cleanup = 0; cleanup < index; cleanup++) free(copies[cleanup]);
      free(copies);
      return NULL;
    }
  }
  return copies;
}

static void free_string_array(char **values, size_t count) {
  if (values == NULL) return;
  for (size_t index = 0; index < count; index++) free(values[index]);
  free(values);
}

static void free_run(WasmtimeRun *run) {
  if (run == NULL) return;
  free(run->name);
  free(run->module_path);
  free_string_array(run->arguments, run->argument_count);
  free_string_array(run->environment_names, run->environment_count);
  free_string_array(run->environment_values, run->environment_count);
  free_string_array(run->preopen_host_paths, run->preopen_count);
  free_string_array(run->preopen_guest_paths, run->preopen_count);
  free(run->preopen_read_only);
  free(run->stdout_path);
  free(run->stderr_path);
  free(run);
}

static WasmtimeRun *find_run_locked(const char *name) {
  for (WasmtimeRun *run = runs; run != NULL; run = run->next) {
    if (strcmp(run->name, name) == 0) return run;
  }
  return NULL;
}

static void remove_run_locked(WasmtimeRun *target) {
  WasmtimeRun **cursor = &runs;
  while (*cursor != NULL) {
    if (*cursor == target) {
      *cursor = target->next;
      return;
    }
    cursor = &(*cursor)->next;
  }
}

static void error_message(const WasmtimeApi *loaded_api,
                          wasmtime_error_t *error,
                          char *message,
                          size_t capacity) {
  if (error == NULL) return;
  wasm_byte_vec_t vector = {0, NULL};
  loaded_api->wasmtime_error_message(error, &vector);
  if (vector.data != NULL && vector.size > 0 && message != NULL && capacity > 0) {
    size_t length = vector.size < capacity - 1 ? vector.size : capacity - 1;
    memcpy(message, vector.data, length);
    message[length] = '\0';
  } else {
    set_message(message, capacity, "Wasmtime operation failed");
  }
  loaded_api->wasm_byte_vec_delete(&vector);
}

#define LOAD_SYMBOL(target, symbol)                                             \
  do {                                                                          \
    *(void **)(&(target)) = dlsym(handle, (symbol));                            \
    if ((target) == NULL) {                                                      \
      dlclose(handle);                                                          \
      memset(&api, 0, sizeof(api));                                             \
      return false;                                                             \
    }                                                                           \
  } while (0)

static bool load_api_locked(const char *const *library_paths, size_t library_count) {
  if (api_loaded) return true;

  const char *defaults[] = {
    "libwasmtime.dylib",
    "libwasmtime.0.dylib",
    "/opt/homebrew/lib/libwasmtime.dylib",
    "/usr/local/lib/libwasmtime.dylib"
  };
  const char *const *paths = library_count > 0 ? library_paths : defaults;
  size_t count = library_count > 0 ? library_count : sizeof(defaults) / sizeof(defaults[0]);
  void *handle = NULL;
  for (size_t index = 0; index < count; index++) {
    if (paths[index] == NULL || paths[index][0] == '\0') continue;
    handle = dlopen(paths[index], RTLD_NOW | RTLD_LOCAL);
    if (handle != NULL) break;
  }
  if (handle == NULL) return false;

  api.handle = handle;
  LOAD_SYMBOL(api.wasm_engine_new_with_config, "wasm_engine_new_with_config");
  LOAD_SYMBOL(api.wasm_engine_delete, "wasm_engine_delete");
  LOAD_SYMBOL(api.wasm_config_new, "wasm_config_new");
  LOAD_SYMBOL(api.wasm_config_delete, "wasm_config_delete");
  LOAD_SYMBOL(api.wasmtime_config_epoch_interruption_set, "wasmtime_config_epoch_interruption_set");
  LOAD_SYMBOL(api.wasmtime_store_new, "wasmtime_store_new");
  LOAD_SYMBOL(api.wasmtime_store_context, "wasmtime_store_context");
  LOAD_SYMBOL(api.wasmtime_store_delete, "wasmtime_store_delete");
  LOAD_SYMBOL(api.wasmtime_context_set_epoch_deadline, "wasmtime_context_set_epoch_deadline");
  LOAD_SYMBOL(api.wasmtime_engine_increment_epoch, "wasmtime_engine_increment_epoch");
  LOAD_SYMBOL(api.wasi_config_new, "wasi_config_new");
  LOAD_SYMBOL(api.wasi_config_delete, "wasi_config_delete");
  LOAD_SYMBOL(api.wasi_config_set_argv, "wasi_config_set_argv");
  LOAD_SYMBOL(api.wasi_config_set_env, "wasi_config_set_env");
  LOAD_SYMBOL(api.wasi_config_set_stdout_file, "wasi_config_set_stdout_file");
  LOAD_SYMBOL(api.wasi_config_set_stderr_file, "wasi_config_set_stderr_file");
  LOAD_SYMBOL(api.wasi_config_preopen_dir, "wasi_config_preopen_dir");
  LOAD_SYMBOL(api.wasmtime_context_set_wasi, "wasmtime_context_set_wasi");
  LOAD_SYMBOL(api.wasmtime_linker_new, "wasmtime_linker_new");
  LOAD_SYMBOL(api.wasmtime_linker_delete, "wasmtime_linker_delete");
  LOAD_SYMBOL(api.wasmtime_linker_define_wasi, "wasmtime_linker_define_wasi");
  LOAD_SYMBOL(api.wasmtime_module_new, "wasmtime_module_new");
  LOAD_SYMBOL(api.wasmtime_module_delete, "wasmtime_module_delete");
  LOAD_SYMBOL(api.wasmtime_linker_instantiate, "wasmtime_linker_instantiate");
  LOAD_SYMBOL(api.wasmtime_instance_export_get, "wasmtime_instance_export_get");
  LOAD_SYMBOL(api.wasmtime_func_call, "wasmtime_func_call");
  LOAD_SYMBOL(api.wasmtime_extern_delete, "wasmtime_extern_delete");
  LOAD_SYMBOL(api.wasmtime_error_delete, "wasmtime_error_delete");
  LOAD_SYMBOL(api.wasmtime_error_message, "wasmtime_error_message");
  LOAD_SYMBOL(api.wasmtime_error_exit_status, "wasmtime_error_exit_status");
  LOAD_SYMBOL(api.wasm_trap_delete, "wasm_trap_delete");
  LOAD_SYMBOL(api.wasm_byte_vec_delete, "wasm_byte_vec_delete");
  api_loaded = true;
  return true;
}

static bool load_api(const char *const *library_paths, size_t library_count) {
  pthread_mutex_lock(&api_mutex);
  bool loaded = load_api_locked(library_paths, library_count);
  pthread_mutex_unlock(&api_mutex);
  return loaded;
}

static bool read_file(const char *path, uint8_t **bytes, size_t *length) {
  FILE *file = fopen(path, "rb");
  if (file == NULL) return false;
  if (fseek(file, 0, SEEK_END) != 0) {
    fclose(file);
    return false;
  }
  long size = ftell(file);
  if (size < 0 || fseek(file, 0, SEEK_SET) != 0) {
    fclose(file);
    return false;
  }
  uint8_t *contents = (uint8_t *)malloc((size_t)size);
  if (contents == NULL && size > 0) {
    fclose(file);
    return false;
  }
  size_t read_count = size > 0 ? fread(contents, 1, (size_t)size, file) : 0;
  fclose(file);
  if (read_count != (size_t)size) {
    free(contents);
    return false;
  }
  *bytes = contents;
  *length = (size_t)size;
  return true;
}

static void finish_run(WasmtimeRun *run, int exit_code, const char *message) {
  pthread_mutex_lock(&runs_mutex);
  run->exit_code = exit_code;
  run->state = WASMBOX_WASMTIME_STOPPED;
  if (message != NULL) set_message(run->message, sizeof(run->message), message);
  pthread_mutex_unlock(&runs_mutex);
}

static void *run_module(void *context) {
  WasmtimeRun *run = (WasmtimeRun *)context;
  const WasmtimeApi *loaded_api = &api;
  int exit_code = 1;
  char failure[1024] = "Wasmtime execution failed";
  uint8_t *wasm_bytes = NULL;
  size_t wasm_length = 0;
  wasm_config_t *config = NULL;
  wasmtime_store_t *store = NULL;
  wasmtime_context_t *store_context = NULL;
  wasi_config_t *wasi = NULL;
  wasmtime_linker_t *linker = NULL;
  wasmtime_module_t *module = NULL;
  wasm_trap_t *trap = NULL;
  wasmtime_error_t *error = NULL;
  bool external_exit = false;

  if (!read_file(run->module_path, &wasm_bytes, &wasm_length)) {
    snprintf(failure, sizeof(failure), "Wasm module could not be read: %s", run->module_path);
    goto done;
  }
  config = loaded_api->wasm_config_new();
  if (config == NULL) {
    snprintf(failure, sizeof(failure), "Wasmtime configuration could not be created");
    goto done;
  }
  loaded_api->wasmtime_config_epoch_interruption_set(config, true);
  wasm_engine_t *engine = loaded_api->wasm_engine_new_with_config(config);
  config = NULL;
  if (engine == NULL) {
    snprintf(failure, sizeof(failure), "Wasmtime engine could not be created");
    goto done;
  }
  pthread_mutex_lock(&runs_mutex);
  run->engine = engine;
  bool stop_requested = run->stop_requested;
  pthread_mutex_unlock(&runs_mutex);
  if (stop_requested) loaded_api->wasmtime_engine_increment_epoch(engine);
  store = loaded_api->wasmtime_store_new(engine, NULL, NULL);
  if (store == NULL) {
    snprintf(failure, sizeof(failure), "Wasmtime store could not be created");
    goto done;
  }
  store_context = loaded_api->wasmtime_store_context(store);
  loaded_api->wasmtime_context_set_epoch_deadline(store_context, 1);
  pthread_mutex_lock(&runs_mutex);
  stop_requested = run->stop_requested;
  pthread_mutex_unlock(&runs_mutex);
  if (stop_requested) loaded_api->wasmtime_engine_increment_epoch(engine);

  wasi = loaded_api->wasi_config_new();
  if (wasi == NULL) {
    snprintf(failure, sizeof(failure), "WASI configuration could not be created");
    goto done;
  }
  size_t argv_count = run->argument_count + 1;
  const char **argv = (const char **)calloc(argv_count, sizeof(char *));
  if (argv == NULL) {
    snprintf(failure, sizeof(failure), "WASI argv allocation failed");
    goto done;
  }
  argv[0] = run->module_path;
  for (size_t index = 0; index < run->argument_count; index++) {
    argv[index + 1] = run->arguments[index];
  }
  if (!loaded_api->wasi_config_set_argv(wasi, argv_count, argv)) {
    free(argv);
    snprintf(failure, sizeof(failure), "WASI argument is not valid UTF-8");
    goto done;
  }
  free(argv);

  if (run->environment_count > 0) {
    const char **names = (const char **)run->environment_names;
    const char **values = (const char **)run->environment_values;
    if (!loaded_api->wasi_config_set_env(wasi, run->environment_count, names, values)) {
      snprintf(failure, sizeof(failure), "WASI environment is not valid UTF-8");
      goto done;
    }
  }
  if (!loaded_api->wasi_config_set_stdout_file(wasi, run->stdout_path)) {
    snprintf(failure, sizeof(failure), "WASI stdout log could not be opened");
    goto done;
  }
  if (!loaded_api->wasi_config_set_stderr_file(wasi, run->stderr_path)) {
    snprintf(failure, sizeof(failure), "WASI stderr log could not be opened");
    goto done;
  }
  for (size_t index = 0; index < run->preopen_count; index++) {
    size_t directory_permissions = 1;
    size_t file_permissions = 1;
    if (!run->preopen_read_only[index]) {
      directory_permissions |= 2;
      file_permissions |= 2;
    }
    if (!loaded_api->wasi_config_preopen_dir(
            wasi,
            run->preopen_host_paths[index],
            run->preopen_guest_paths[index],
            directory_permissions,
            file_permissions)) {
      snprintf(failure, sizeof(failure), "WASI preopen could not be configured: %s",
               run->preopen_host_paths[index]);
      goto done;
    }
  }
  error = loaded_api->wasmtime_context_set_wasi(store_context, wasi);
  wasi = NULL;
  if (error != NULL) {
    error_message(loaded_api, error, failure, sizeof(failure));
    loaded_api->wasmtime_error_delete(error);
    error = NULL;
    goto done;
  }

  linker = loaded_api->wasmtime_linker_new(run->engine);
  if (linker == NULL) {
    snprintf(failure, sizeof(failure), "Wasmtime linker could not be created");
    goto done;
  }
  error = loaded_api->wasmtime_linker_define_wasi(linker);
  if (error != NULL) {
    error_message(loaded_api, error, failure, sizeof(failure));
    loaded_api->wasmtime_error_delete(error);
    error = NULL;
    goto done;
  }
  error = loaded_api->wasmtime_module_new(
      run->engine, wasm_bytes, wasm_length, &module);
  if (error != NULL) {
    error_message(loaded_api, error, failure, sizeof(failure));
    loaded_api->wasmtime_error_delete(error);
    error = NULL;
    goto done;
  }
  wasmtime_instance_t instance;
  memset(&instance, 0, sizeof(instance));
  error = loaded_api->wasmtime_linker_instantiate(
      linker, store_context, module, &instance, &trap);
  if (error != NULL) {
    error_message(loaded_api, error, failure, sizeof(failure));
    loaded_api->wasmtime_error_delete(error);
    error = NULL;
    goto done;
  }
  if (trap != NULL) {
    snprintf(failure, sizeof(failure), "Wasm module initialization trapped");
    goto done;
  }

  wasmtime_extern_t start;
  memset(&start, 0, sizeof(start));
  if (!loaded_api->wasmtime_instance_export_get(
          store_context, &instance, "_start", 6, &start)) {
    snprintf(failure, sizeof(failure), "Wasm module does not export _start");
    goto done;
  }
  if (start.kind != 0) {
    loaded_api->wasmtime_extern_delete(&start);
    snprintf(failure, sizeof(failure), "Wasm _start export is not a function");
    goto done;
  }
  error = loaded_api->wasmtime_func_call(
      store_context, &start.of.func, NULL, 0, NULL, 0, &trap);
  loaded_api->wasmtime_extern_delete(&start);
  if (error != NULL) {
    int status = 1;
    external_exit = loaded_api->wasmtime_error_exit_status(error, &status);
    exit_code = external_exit ? status : 1;
    if (!external_exit) error_message(loaded_api, error, failure, sizeof(failure));
    loaded_api->wasmtime_error_delete(error);
    error = NULL;
    goto done;
  }
  if (trap != NULL) {
    snprintf(failure, sizeof(failure), "Wasm execution trapped");
    goto done;
  }
  exit_code = 0;

done:
  if (error != NULL) loaded_api->wasmtime_error_delete(error);
  if (trap != NULL) loaded_api->wasm_trap_delete(trap);
  if (module != NULL) loaded_api->wasmtime_module_delete(module);
  if (linker != NULL) loaded_api->wasmtime_linker_delete(linker);
  if (store != NULL) loaded_api->wasmtime_store_delete(store);
  pthread_mutex_lock(&runs_mutex);
  wasm_engine_t *engine_to_delete = run->engine;
  run->engine = NULL;
  bool stopped = run->stop_requested;
  pthread_mutex_unlock(&runs_mutex);
  if (engine_to_delete != NULL) loaded_api->wasm_engine_delete(engine_to_delete);
  if (config != NULL) loaded_api->wasm_config_delete(config);
  if (wasi != NULL) loaded_api->wasi_config_delete(wasi);
  free(wasm_bytes);

  if (stopped) {
    exit_code = 143;
    snprintf(failure, sizeof(failure), "Wasm run stopped");
  }
  finish_run(run, exit_code, exit_code == 0 ? NULL : failure);
  return NULL;
}

int wasmbox_wasmtime_runtime_available(
    const char *const *library_paths,
    size_t library_count,
    char *message,
    size_t message_capacity) {
  if (!load_api(library_paths, library_count)) {
    set_message(message, message_capacity, "Wasmtime C API could not be loaded");
    return 0;
  }
  set_message(message, message_capacity, "Wasmtime C API loaded");
  return 1;
}

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
    size_t message_capacity) {
  if (!load_api(NULL, 0)) {
    set_message(message, message_capacity, "Wasmtime C API could not be loaded");
    return 0;
  }
  if (runtime_name == NULL || module_path == NULL || stdout_path == NULL || stderr_path == NULL) {
    set_message(message, message_capacity, "Wasmtime start received an invalid path");
    return 0;
  }
  WasmtimeRun *run = (WasmtimeRun *)calloc(1, sizeof(WasmtimeRun));
  if (run == NULL) {
    set_message(message, message_capacity, "Wasmtime run allocation failed");
    return 0;
  }
  run->name = copy_string(runtime_name);
  run->module_path = copy_string(module_path);
  run->arguments = copy_string_array(arguments, argument_count);
  run->argument_count = argument_count;
  run->environment_names = copy_string_array(environment_names, environment_count);
  run->environment_values = copy_string_array(environment_values, environment_count);
  run->environment_count = environment_count;
  run->preopen_host_paths = copy_string_array(preopen_host_paths, preopen_count);
  run->preopen_guest_paths = copy_string_array(preopen_guest_paths, preopen_count);
  run->preopen_read_only = preopen_count > 0
      ? (int *)calloc(preopen_count, sizeof(int))
      : NULL;
  run->preopen_count = preopen_count;
  run->stdout_path = copy_string(stdout_path);
  run->stderr_path = copy_string(stderr_path);
  run->state = WASMBOX_WASMTIME_RUNNING;
  run->exit_code = -1;
  if (run->name == NULL || run->module_path == NULL
      || (argument_count > 0 && run->arguments == NULL)
      || (environment_count > 0 &&
          (run->environment_names == NULL || run->environment_values == NULL))
      || (preopen_count > 0 &&
          (run->preopen_host_paths == NULL || run->preopen_guest_paths == NULL
           || run->preopen_read_only == NULL))
      || run->stdout_path == NULL || run->stderr_path == NULL) {
    free_run(run);
    set_message(message, message_capacity, "Wasmtime run allocation failed");
    return 0;
  }
  for (size_t index = 0; index < preopen_count; index++) {
    run->preopen_read_only[index] = preopen_read_only == NULL ? 1 : preopen_read_only[index];
  }

  pthread_mutex_lock(&runs_mutex);
  if (find_run_locked(runtime_name) != NULL) {
    pthread_mutex_unlock(&runs_mutex);
    free_run(run);
    set_message(message, message_capacity, "Wasmtime runtime name is already running");
    return 0;
  }
  run->next = runs;
  runs = run;
  pthread_mutex_unlock(&runs_mutex);

  if (pthread_create(&run->thread, NULL, run_module, run) != 0) {
    pthread_mutex_lock(&runs_mutex);
    remove_run_locked(run);
    pthread_mutex_unlock(&runs_mutex);
    free_run(run);
    set_message(message, message_capacity, "Wasmtime worker thread could not be created");
    return 0;
  }
  run->thread_started = true;
  return 1;
}

int wasmbox_wasmtime_stop(
    const char *runtime_name,
    unsigned int timeout_milliseconds,
    char *message,
    size_t message_capacity) {
  if (!load_api(NULL, 0)) {
    set_message(message, message_capacity, "Wasmtime C API could not be loaded");
    return 0;
  }
  pthread_mutex_lock(&runs_mutex);
  WasmtimeRun *run = find_run_locked(runtime_name);
  if (run == NULL) {
    pthread_mutex_unlock(&runs_mutex);
    set_message(message, message_capacity, "Wasmtime run was not found");
    return 0;
  }
  run->stop_requested = true;
  wasm_engine_t *engine = run->engine;
  pthread_mutex_unlock(&runs_mutex);

  if (engine != NULL) api.wasmtime_engine_increment_epoch(engine);
  unsigned int waited = 0;
  const unsigned int limit = timeout_milliseconds == 0 ? 1000 : timeout_milliseconds;
  while (waited < limit) {
    pthread_mutex_lock(&runs_mutex);
    bool stopped = run->state == WASMBOX_WASMTIME_STOPPED;
    pthread_mutex_unlock(&runs_mutex);
    if (stopped) break;
    struct timespec interval = {.tv_sec = 0, .tv_nsec = 10 * 1000 * 1000};
    nanosleep(&interval, NULL);
    waited += 10;
  }

  pthread_mutex_lock(&runs_mutex);
  bool stopped = run->state == WASMBOX_WASMTIME_STOPPED;
  pthread_mutex_unlock(&runs_mutex);
  if (!stopped) {
    set_message(message, message_capacity, "Wasmtime instance did not stop before timeout");
    return 0;
  }
  if (run->thread_started) pthread_join(run->thread, NULL);
  pthread_mutex_lock(&runs_mutex);
  remove_run_locked(run);
  pthread_mutex_unlock(&runs_mutex);
  free_run(run);
  set_message(message, message_capacity, "");
  return 1;
}

int wasmbox_wasmtime_inspect(
    const char *runtime_name,
    int *state,
    int *exit_code,
    char *message,
    size_t message_capacity) {
  if (state == NULL || exit_code == NULL) {
    set_message(message, message_capacity, "Wasmtime inspect received invalid output pointers");
    return 0;
  }
  pthread_mutex_lock(&runs_mutex);
  WasmtimeRun *run = find_run_locked(runtime_name);
  if (run == NULL) {
    pthread_mutex_unlock(&runs_mutex);
    *state = WASMBOX_WASMTIME_STOPPED;
    *exit_code = -1;
    set_message(message, message_capacity, "Wasmtime run was not found");
    return 0;
  }
  *state = run->state;
  *exit_code = run->exit_code;
  set_message(message, message_capacity, run->message);
  bool finished = run->state == WASMBOX_WASMTIME_STOPPED;
  pthread_mutex_unlock(&runs_mutex);
  if (finished && run->thread_started) {
    pthread_join(run->thread, NULL);
    pthread_mutex_lock(&runs_mutex);
    if (find_run_locked(runtime_name) == run) remove_run_locked(run);
    pthread_mutex_unlock(&runs_mutex);
    free_run(run);
  }
  return 1;
}
