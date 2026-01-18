/**
 * CLAP Plugin Entry Point - Minimal C Shim
 *
 * This ~80 LOC C file is the only C code in the entire plugin.
 * All actual logic is implemented in OCaml and called via caml_callback.
 *
 * CLAP Specification: https://github.com/free-audio/clap
 */

#include <string.h>
#include <stdlib.h>
#include <stdbool.h>
#include <stdint.h>

/* CLAP headers (simplified inline definitions) */
#define CLAP_VERSION_MAJOR 1
#define CLAP_VERSION_MINOR 2
#define CLAP_VERSION_REVISION 0

typedef struct clap_version {
    uint32_t major, minor, revision;
} clap_version_t;

static const clap_version_t CLAP_VERSION = {
    CLAP_VERSION_MAJOR, CLAP_VERSION_MINOR, CLAP_VERSION_REVISION
};

typedef struct clap_plugin_descriptor {
    clap_version_t clap_version;
    const char *id;
    const char *name;
    const char *vendor;
    const char *url;
    const char *manual_url;
    const char *support_url;
    const char *version;
    const char *description;
    const char *const *features;
} clap_plugin_descriptor_t;

typedef struct clap_host clap_host_t;
typedef struct clap_plugin clap_plugin_t;

typedef struct clap_plugin {
    const clap_plugin_descriptor_t *desc;
    void *plugin_data;

    bool (*init)(const clap_plugin_t *plugin);
    void (*destroy)(const clap_plugin_t *plugin);
    bool (*activate)(const clap_plugin_t *plugin, double sample_rate,
                     uint32_t min_frames, uint32_t max_frames);
    void (*deactivate)(const clap_plugin_t *plugin);
    bool (*start_processing)(const clap_plugin_t *plugin);
    void (*stop_processing)(const clap_plugin_t *plugin);
    void (*reset)(const clap_plugin_t *plugin);
    int (*process)(const clap_plugin_t *plugin, void *process);
    const void *(*get_extension)(const clap_plugin_t *plugin, const char *id);
    void (*on_main_thread)(const clap_plugin_t *plugin);
} clap_plugin_t;

typedef struct clap_plugin_factory {
    uint32_t (*get_plugin_count)(const struct clap_plugin_factory *factory);
    const clap_plugin_descriptor_t *(*get_plugin_descriptor)(
        const struct clap_plugin_factory *factory, uint32_t index);
    const clap_plugin_t *(*create_plugin)(
        const struct clap_plugin_factory *factory,
        const clap_host_t *host, const char *plugin_id);
} clap_plugin_factory_t;

typedef struct clap_plugin_entry {
    clap_version_t clap_version;
    bool (*init)(const char *plugin_path);
    void (*deinit)(void);
    const void *(*get_factory)(const char *factory_id);
} clap_plugin_entry_t;

/* OCaml Runtime */
#include <caml/mlvalues.h>
#include <caml/callback.h>
#include <caml/memory.h>
#include <caml/alloc.h>

/* Plugin State - holds OCaml value */
typedef struct {
    value ocaml_plugin;  /* OCaml plugin instance */
    const clap_host_t *host;
} daw_bridge_state_t;

/* Plugin Descriptor */
static const char *features[] = { "utility", "analyzer", NULL };

static const clap_plugin_descriptor_t s_descriptor = {
    .clap_version = CLAP_VERSION,
    .id = "com.dancer.daw-bridge",
    .name = "DAW Bridge",
    .vendor = "Dancer",
    .url = "https://github.com/dancer/me",
    .manual_url = "",
    .support_url = "",
    .version = "1.0.0",
    .description = "MCP Bridge for AI control of DAW",
    .features = features,
};

/* Forward declarations */
static bool plugin_init(const clap_plugin_t *plugin);
static void plugin_destroy(const clap_plugin_t *plugin);
static bool plugin_activate(const clap_plugin_t *plugin, double sample_rate,
                           uint32_t min_frames, uint32_t max_frames);
static void plugin_deactivate(const clap_plugin_t *plugin);
static bool plugin_start_processing(const clap_plugin_t *plugin);
static void plugin_stop_processing(const clap_plugin_t *plugin);
static void plugin_reset(const clap_plugin_t *plugin);
static int plugin_process(const clap_plugin_t *plugin, void *process);
static const void *plugin_get_extension(const clap_plugin_t *plugin, const char *id);
static void plugin_on_main_thread(const clap_plugin_t *plugin);

/* Plugin Implementation */
static bool plugin_init(const clap_plugin_t *plugin) {
    daw_bridge_state_t *state = (daw_bridge_state_t *)plugin->plugin_data;

    /* Call OCaml: Bridge.init () */
    static const value *ocaml_init = NULL;
    if (ocaml_init == NULL) {
        ocaml_init = caml_named_value("daw_bridge_init");
    }
    if (ocaml_init != NULL) {
        state->ocaml_plugin = caml_callback(*ocaml_init, Val_unit);
        caml_register_global_root(&state->ocaml_plugin);
        return true;
    }
    return false;
}

static void plugin_destroy(const clap_plugin_t *plugin) {
    daw_bridge_state_t *state = (daw_bridge_state_t *)plugin->plugin_data;

    /* Call OCaml: Bridge.destroy plugin */
    static const value *ocaml_destroy = NULL;
    if (ocaml_destroy == NULL) {
        ocaml_destroy = caml_named_value("daw_bridge_destroy");
    }
    if (ocaml_destroy != NULL && state->ocaml_plugin != Val_unit) {
        caml_callback(*ocaml_destroy, state->ocaml_plugin);
        caml_remove_global_root(&state->ocaml_plugin);
    }

    free(state);
    free((void *)plugin);
}

static bool plugin_activate(const clap_plugin_t *plugin, double sample_rate,
                           uint32_t min_frames, uint32_t max_frames) {
    daw_bridge_state_t *state = (daw_bridge_state_t *)plugin->plugin_data;

    /* Call OCaml: Bridge.activate plugin sample_rate */
    static const value *ocaml_activate = NULL;
    if (ocaml_activate == NULL) {
        ocaml_activate = caml_named_value("daw_bridge_activate");
    }
    if (ocaml_activate != NULL) {
        value args[3] = {
            state->ocaml_plugin,
            caml_copy_double(sample_rate),
            Val_int(max_frames)
        };
        caml_callbackN(*ocaml_activate, 3, args);
        return true;
    }
    return false;
}

static void plugin_deactivate(const clap_plugin_t *plugin) {
    daw_bridge_state_t *state = (daw_bridge_state_t *)plugin->plugin_data;

    static const value *ocaml_deactivate = NULL;
    if (ocaml_deactivate == NULL) {
        ocaml_deactivate = caml_named_value("daw_bridge_deactivate");
    }
    if (ocaml_deactivate != NULL) {
        caml_callback(*ocaml_deactivate, state->ocaml_plugin);
    }
}

static bool plugin_start_processing(const clap_plugin_t *plugin) {
    (void)plugin;
    return true;
}

static void plugin_stop_processing(const clap_plugin_t *plugin) {
    (void)plugin;
}

static void plugin_reset(const clap_plugin_t *plugin) {
    (void)plugin;
}

static int plugin_process(const clap_plugin_t *plugin, void *process) {
    daw_bridge_state_t *state = (daw_bridge_state_t *)plugin->plugin_data;

    /* Call OCaml: Bridge.process plugin */
    static const value *ocaml_process = NULL;
    if (ocaml_process == NULL) {
        ocaml_process = caml_named_value("daw_bridge_process");
    }
    if (ocaml_process != NULL) {
        caml_callback(*ocaml_process, state->ocaml_plugin);
    }

    (void)process;
    return 0; /* CLAP_PROCESS_CONTINUE */
}

static const void *plugin_get_extension(const clap_plugin_t *plugin, const char *id) {
    (void)plugin;
    (void)id;
    return NULL;
}

static void plugin_on_main_thread(const clap_plugin_t *plugin) {
    (void)plugin;
}

/* Factory */
static uint32_t factory_get_plugin_count(const clap_plugin_factory_t *factory) {
    (void)factory;
    return 1;
}

static const clap_plugin_descriptor_t *factory_get_plugin_descriptor(
    const clap_plugin_factory_t *factory, uint32_t index) {
    (void)factory;
    return index == 0 ? &s_descriptor : NULL;
}

static const clap_plugin_t *factory_create_plugin(
    const clap_plugin_factory_t *factory,
    const clap_host_t *host, const char *plugin_id) {
    (void)factory;

    if (strcmp(plugin_id, s_descriptor.id) != 0) {
        return NULL;
    }

    clap_plugin_t *plugin = (clap_plugin_t *)calloc(1, sizeof(clap_plugin_t));
    daw_bridge_state_t *state = (daw_bridge_state_t *)calloc(1, sizeof(daw_bridge_state_t));

    state->host = host;
    state->ocaml_plugin = Val_unit;

    plugin->desc = &s_descriptor;
    plugin->plugin_data = state;
    plugin->init = plugin_init;
    plugin->destroy = plugin_destroy;
    plugin->activate = plugin_activate;
    plugin->deactivate = plugin_deactivate;
    plugin->start_processing = plugin_start_processing;
    plugin->stop_processing = plugin_stop_processing;
    plugin->reset = plugin_reset;
    plugin->process = plugin_process;
    plugin->get_extension = plugin_get_extension;
    plugin->on_main_thread = plugin_on_main_thread;

    return plugin;
}

static const clap_plugin_factory_t s_factory = {
    .get_plugin_count = factory_get_plugin_count,
    .get_plugin_descriptor = factory_get_plugin_descriptor,
    .create_plugin = factory_create_plugin,
};

/* Entry Point */
static bool entry_init(const char *plugin_path) {
    (void)plugin_path;

    /* Initialize OCaml runtime */
    char *argv[] = { "daw-bridge", NULL };
    caml_startup(argv);

    return true;
}

static void entry_deinit(void) {
    /* OCaml runtime cleanup handled automatically */
}

static const void *entry_get_factory(const char *factory_id) {
    if (strcmp(factory_id, "clap.plugin-factory") == 0) {
        return &s_factory;
    }
    return NULL;
}

/* Export the entry point */
__attribute__((visibility("default")))
const clap_plugin_entry_t clap_entry = {
    .clap_version = CLAP_VERSION,
    .init = entry_init,
    .deinit = entry_deinit,
    .get_factory = entry_get_factory,
};
