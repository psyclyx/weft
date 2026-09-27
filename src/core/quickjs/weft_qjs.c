// weft_qjs.c — the QuickJS-ng embedding shim, compiled to a wasm32-wasi
// reactor (build.zig `addQuickjs`) and embedded as `quickjs.wasm`. This is
// the runtime behind weft's user config: `config.js` is evaluated here, and
// the host drives it across the sandbox membrane exactly like a `.wasm`
// plugin — malloc a buffer, write the JS source into linear memory, call
// `weft_eval`. The `weft.*` config surface (bindKey/command/echo/log) is
// installed as a JS global backed by host imports (see `install_weft`).
//
// Kept deliberately small: the core engine .c files (quickjs.c, dtoa.c,
// libregexp.c, libunicode.c) compile in via build.zig; this file is only the
// weft↔JS bridge. No quickjs-libc (no os/std JS modules) — the config plane
// is pure declaration, not a general JS host.

#include "quickjs.h"
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

// ── Host imports (grants), module "weft" — the same membrane the Zig plugin
// shim uses. Strings cross as (ptr,len) into this module's linear memory,
// which the host reads. ──
#define WEFT_RUN_MAX_ARGS 8
#define WEFT_RUN_MAX_ARG_BYTES 1024
#define WEFT_RUN_MAX_TOTAL_BYTES 4096
typedef struct {
    const char *ptr;
    int len;
} WeftRunArg;

// weft.bind(scope, key, intention | [intentions]): the third argument crosses
// as a FRAMED list (uvarint count, then uvarint(len)++bytes per entry — the
// same encoding weft.set uses), so the string form is simply a one-entry list.
#define WEFT_BIND_MAX_CMDS 8
__attribute__((import_module("weft"), import_name("qjs_bind_key")))
extern void host_bind_key(const char *mode, int mode_len,
                          const char *key, int key_len,
                          const char *cmds, int cmds_len);
__attribute__((import_module("weft"), import_name("qjs_run")))
extern void host_run(const char *cmd, int cmd_len,
                     const WeftRunArg *args, int arg_count);
__attribute__((import_module("weft"), import_name("qjs_echo")))
extern void host_echo(const char *msg, int msg_len);
__attribute__((import_module("weft"), import_name("qjs_log")))
extern void host_log(const char *msg, int msg_len);
__attribute__((import_module("weft"), import_name("qjs_plugin")))
extern void host_plugin(const char *name, int name_len);
// weft.use(name): evaluate `<config_dir>/<name>.js` into its OWN imported
// sub-manifest, entirely host-side (a nested `evalToManifest` call, its own
// fresh quickjs runtime — see core/quickjs.zig's `cUse`). Fire-and-forget:
// there is nothing for the guest to do afterward (no nested JS_Eval here
// anymore — the host does the whole sub-evaluation).
__attribute__((import_module("weft"), import_name("qjs_use")))
extern void host_use(const char *name, int name_len);
__attribute__((import_module("weft"), import_name("qjs_set")))
extern void host_set(const char *plugin, int plugin_len,
                     const char *key, int key_len,
                     const char *blob, int blob_len);
__attribute__((import_module("weft"), import_name("qjs_menu")))
extern void host_menu(const char *name, int name_len);
__attribute__((import_module("weft"), import_name("qjs_group")))
extern void host_group(const char *mode, int mode_len,
                       const char *prefix, int prefix_len,
                       const char *name, int name_len);
// Plugin plane (persistent runtime): register a command, get a host-assigned id
// (the value the host passes back to weft_on_command). Config satisfies this
// import with a stub (it never registers commands).
__attribute__((import_module("weft"), import_name("qjs_register")))
extern int host_register(const char *name, int name_len);
// The declare doors, identical in name and shape to the wasm plane's
// `wl_declare_command*` and bound to the very same host bodies. `weft.command`
// declares, then registers — the two halves a `.wasm` plugin does in describe()
// and init(), which a JS plugin has no describe phase to separate.
__attribute__((import_module("weft"), import_name("qjs_declare_command_doc")))
extern void host_declare_command_doc(const char *name, int name_len,
                                     const char *params, int params_len,
                                     const char *summary, int summary_len);
// How a declared command maps over several selections (`wl_declare_arity`,
// same body): 0 each, 1 whole, 2 homogeneous.
__attribute__((import_module("weft"), import_name("qjs_declare_arity")))
extern void host_declare_arity(const char *name, int name_len, int code,
                               const char *over, int over_len);
// How a declared command is presented (`wl_declare_command_meta`, same body).
__attribute__((import_module("weft"), import_name("qjs_declare_command_meta")))
extern void host_declare_command_meta(const char *name, int name_len,
                                      const char *meta, int meta_len);
// What a name is called here, and which key runs it (`wl_command_meta` and
// `wl_keys_for`, same bodies): the full length, written only when it fits.
__attribute__((import_module("weft"), import_name("qjs_command_meta")))
extern int host_command_meta(const char *name, int name_len, char *out, int cap);
__attribute__((import_module("weft"), import_name("qjs_keys_for")))
extern int host_keys_for(const char *name, int name_len, char *out, int cap);
// Plugin proc-stream membrane: a persistent duplex child whose stdout the guest
// reads (an ACP agent, an LSP-shaped tool). Config satisfies these with stubs.
__attribute__((import_module("weft"), import_name("qjs_proc_spawn")))
extern int host_proc_spawn(const char *cmd, int cmd_len);
__attribute__((import_module("weft"), import_name("qjs_proc_send")))
extern void host_proc_send(int handle, const char *ptr, int len);
__attribute__((import_module("weft"), import_name("qjs_proc_read")))
extern int host_proc_read(int handle, char *out, int cap);
__attribute__((import_module("weft"), import_name("qjs_proc_close")))
extern void host_proc_close(int handle);
// Append text to a named buffer (created if absent) — a transcript/tool buffer
// the plugin owns, targeted by name so it need not be focused. Config stubs it.
__attribute__((import_module("weft"), import_name("qjs_buffer_append")))
extern void host_buffer_append(const char *name, int name_len, const char *text, int text_len, int style_class);
// Collapse [start,end) of a named buffer (fold a tool-call's content).
__attribute__((import_module("weft"), import_name("qjs_buffer_fold")))
extern void host_buffer_fold(const char *name, int name_len, int start, int end);
// A named buffer's byte length — for computing fold offsets.
__attribute__((import_module("weft"), import_name("qjs_buffer_len")))
extern int host_buffer_len(const char *name, int name_len);
// W6 check-in producer seam (doc/agents.md, north-star-plan.md §6 W5/W6):
// start a new role-tagged entry in the live TranscriptDoc `name` projects
// (one conversation per buffer name, minted on first call), re-filling that
// buffer from the model. Config stubs it (never called there).
__attribute__((import_module("weft"), import_name("qjs_transcript_entry")))
extern void host_transcript_entry(const char *name, int name_len,
                                  const char *role, int role_len,
                                  const char *text, int text_len);
// Stream a chunk onto the currently-open entry's body (a real text-CRDT
// insert), re-filling `name`'s projected buffer the same way.
__attribute__((import_module("weft"), import_name("qjs_transcript_append")))
extern void host_transcript_append(const char *name, int name_len,
                                   const char *text, int text_len);
// Read this plugin's config value for `key` (staged by weft.set) into `out`.
__attribute__((import_module("weft"), import_name("qjs_config")))
extern int host_config(const char *key, int key_len, char *out, int cap);

// Read a file's breakpoint lines (a "l1,l2,…" CSV, published by the debug
// plugin) into `out`; returns the byte count. Backs `weft.breakpoints`.
__attribute__((import_module("weft"), import_name("qjs_breakpoints")))
extern int host_breakpoints(const char *path, int path_len, char *out, int cap);
// Read a file's content (the live buffer if open, else disk) into `out` — the
// agent's fs/read_text_file, answered by the harness. Config stubs it.
__attribute__((import_module("weft"), import_name("qjs_file_read")))
extern int host_file_read(const char *path, int path_len, char *out, int cap);
// Write a file's content as an attributed AGENT peer edit to its buffer (opened
// if needed) — the agent's fs/write_text_file, so the edit is gated + undoable.
// Returns 0, or WEFT_DENIED when `fs_write` is unheld or the path falls
// outside the grant's root — a refusal must never look like a write.
__attribute__((import_module("weft"), import_name("qjs_file_write")))
extern int host_file_write(const char *path, int path_len, const char *content, int content_len, const char *agent, int agent_len);
// The READ surface — the same wasm_host/edit.zig bodies `wl_cursor`/`wl_slice`/…
// run. A JS plugin runs inside this very wasm module, so it reads the buffer it
// is in through the same code a wasm plugin does. Config stubs them.
__attribute__((import_module("weft"), import_name("qjs_cursor")))
extern int host_cursor(void);
__attribute__((import_module("weft"), import_name("qjs_byte_len")))
extern int host_byte_len(void);
__attribute__((import_module("weft"), import_name("qjs_slice")))
extern int host_slice(int start, int end, char *out, int cap);
__attribute__((import_module("weft"), import_name("qjs_line_at")))
extern void host_line_at(int offset, int *out_pair);
__attribute__((import_module("weft"), import_name("qjs_selection")))
extern int host_selection(int *out_pair);
__attribute__((import_module("weft"), import_name("qjs_path")))
extern int host_path(char *out, int cap);
__attribute__((import_module("weft"), import_name("qjs_jump")))
extern void host_jump(int offset);
// The pointer facts of the dispatch in flight — wasm_host/pointer.zig's body,
// the one `wl_pointer` runs: eight u32 words, 0 when there is no gesture.
__attribute__((import_module("weft"), import_name("qjs_pointer")))
extern int host_pointer(unsigned *out_words);
// The system clipboard (grant: clipboard, config-only) — wasm_host/clipboard.zig's
// bodies. `get` answers the FULL length, so a caller whose buffer was short
// can ask again; both answer WEFT_DENIED without the grant.
__attribute__((import_module("weft"), import_name("qjs_clipboard_set")))
extern int host_clipboard_set(const char *text, int len);
__attribute__((import_module("weft"), import_name("qjs_clipboard_get")))
extern int host_clipboard_get(char *out, int cap);
// Context — wasm_host/context.zig's bodies. `set` answers 0, -1 (a key that
// is not namespaced, an oversized value, a bad scope) or -2 (another plugin
// holds the key there); `get` answers the FULL length, or -1 for no value.
__attribute__((import_module("weft"), import_name("qjs_context_set")))
extern int host_context_set(const char *key, int key_len, const char *value, int value_len, int scope, const char *place, int place_len);
__attribute__((import_module("weft"), import_name("qjs_context_get")))
extern int host_context_get(const char *key, int key_len, char *out, int cap);
// The keys the context delivery in flight moved, and the workspace's places:
// one per line, answering the FULL length. A subject watch (1 on, 0 off)
// answers 0, -1 (not a designation) or -2 (too many).
__attribute__((import_module("weft"), import_name("qjs_context_changed")))
extern int host_context_changed(char *out, int cap);
// Whether a context handler is installed (1) or not (0): the host delivers
// the event only to a plugin that has one.
__attribute__((import_module("weft"), import_name("qjs_context_listen")))
extern void host_context_listen(int on);
__attribute__((import_module("weft"), import_name("qjs_places")))
extern int host_places(char *out, int cap);
__attribute__((import_module("weft"), import_name("qjs_subject_watch")))
extern int host_subject_watch(const char *subject, int len, int watching);
// The tool doors — wasm_host/tool.zig's bodies, creator and namespace rules
// included. `designation` answers the FULL length, or -1 for none;
// `designate` 0 or a negative refusal; the opener 0, -1, -2 or -3.
__attribute__((import_module("weft"), import_name("qjs_tool_backing")))
extern void host_tool_backing(const char *name, int len);
__attribute__((import_module("weft"), import_name("qjs_designation")))
extern int host_designation(char *out, int cap);
__attribute__((import_module("weft"), import_name("qjs_designate")))
extern int host_designate(const char *text, int len);
__attribute__((import_module("weft"), import_name("qjs_designation_opener")))
extern int host_designation_opener(const char *kind, int kind_len, const char *cmd, int cmd_len);
// The head's history — wasm_host/history.zig's bodies.
__attribute__((import_module("weft"), import_name("qjs_jump_push")))
extern void host_jump_push(void);
__attribute__((import_module("weft"), import_name("qjs_macro_recording")))
extern int host_macro_recording(void);
// The text of the active buffer's current line (at the cursor) — a prompt line.
__attribute__((import_module("weft"), import_name("qjs_line_text")))
extern int host_line_text(char *out, int cap);
// The focused buffer's display name — how an instanced tool decides which of
// its sessions a command is about.
__attribute__((import_module("weft"), import_name("qjs_active_buffer")))
extern int host_active_buffer(char *out, int cap);
// Open a pick (prompt + newline-joined options); the structured acceptance
// comes back via weft_on_pick carrying `token` — the opaque continuation
// identity the caller minted, so an async approve/deny answers the ONE
// request it was opened for even with several in flight.
__attribute__((import_module("weft"), import_name("qjs_pick")))
extern void host_pick(const char *prompt, int plen, const char *opts, int olen,
                      const char *token, int tlen);
// Set the status-line chip (the "● agent · waiting" indicator). "" clears it.
__attribute__((import_module("weft"), import_name("qjs_status")))
extern void host_status(const char *text, int len);
__attribute__((import_module("weft"), import_name("qjs_action")))
extern void host_action(const char *name, int name_len);
// weft.command(id, {label, summary, menu, …}): describe how a command is
// presented, at the config tier (doc/chrome.md §1.2). `meta` is the shared
// text form (`weft_membrane.presentation`). Plugins stub it.
__attribute__((import_module("weft"), import_name("qjs_describe")))
extern void host_describe(const char *name, int name_len, const char *meta, int meta_len);
__attribute__((import_module("weft"), import_name("qjs_semantic_action")))
extern void host_semantic_action(const char *name, int name_len);
__attribute__((import_module("weft"), import_name("qjs_provide")))
extern void host_provide(const char *action, int action_len,
                         const char *when_json, int when_len,
                         const char *cmd, int cmd_len,
                         const char *opts_json, int opts_len);
// weft.statusSegment(text, role, priority): stage a static ui/statusline-seg
// segment onto the manifest (north-star-plan §6 W3, task #19 item 3).
__attribute__((import_module("weft"), import_name("qjs_status_segment")))
extern void host_status_segment(const char *text, int text_len,
                                const char *role, int role_len, int priority,
                                const char *command, int command_len);
// weft.grant(plugin, capability, opts): stage a GrantDecl onto the manifest
// (north-star-plan §6 W4 slice 4). `root` is opts.root ("" = unrestricted,
// Limit.none; non-empty narrows to Limit.fs_root) — the only limit kind a
// config script can author in v1 (see manifest.zig's ManifestGrantDecl doc
// for why doc-region limits stay runtime-only).
__attribute__((import_module("weft"), import_name("qjs_grant")))
extern void host_grant(const char *plugin, int plugin_len,
                       const char *capability, int capability_len,
                       const char *root, int root_len);
// weft.viewport(name, opts): stage a viewport declaration
// (doc/configuration.md §5.2). `flags` is the attribute bundle as bits (see
// WEFT_VP_* below) and `extent` is per-mille of the frame, because the host
// import ABI carries i32s only — the pair is decoded once, host-side.
__attribute__((import_module("weft"), import_name("qjs_viewport")))
extern void host_viewport(const char *name, int name_len,
                          const char *edge, int edge_len,
                          int flags, int extent_permille);
// weft.present(viewport, opts): stage "show this subject in that viewport".
// `flags` bit 0: the subject is a context key; bit 1: so is the reveal.
__attribute__((import_module("weft"), import_name("qjs_present")))
extern void host_present(const char *viewport, int viewport_len,
                         const char *subject, int subject_len,
                         const char *as, int as_len,
                         const char *reveal, int reveal_len,
                         int flags);

#define WEFT_VP_CYCLES (1 << 0)
#define WEFT_VP_PERSISTENT (1 << 1)
#define WEFT_VP_FOCUS_SOURCE (1 << 2)
#define WEFT_VP_TAKES_FOCUS (1 << 3)
#define WEFT_VP_STATUS_LINE (1 << 4)
#define WEFT_VP_EXTENT_ROWS (1 << 5)
#define WEFT_VP_HIDDEN (1 << 6)

// The result an i32-returning effect import answers when this plugin holds no
// grant for the capability it needs (core/membrane/qjs_contract.zig's
// `denied` — the two numbers must agree). Distinct from -1/0, which are
// mundane failures a plugin may ignore: a denial becomes a thrown JS
// exception at the weft.* call site, so it can never read as success.
#define WEFT_DENIED (-2)

static JSValue weft_throw_denied(JSContext *ctx, const char *verb) {
    return JS_ThrowInternalError(
        ctx, "weft.%s: permission denied — this plugin holds no grant for it "
             "(declare one with weft.grant in your config)", verb);
}

// ── JS → host trampolines. Each pulls its string args out of the JS values
// and forwards to the host import. `weft.run` is the generic command door:
// zero arguments remains valid, while bounded string arguments are carried as
// borrowed ptr/len records for the duration of the host call. ──

// Record framing: uvarint(count) then count×(uvarint(len) ++ bytes) — the
// LEB128 style kv/guest use, so a decoder can detect a short/truncated buffer
// rather than silently dropping tail records. Shared by `weft.bind`'s
// intention list and `weft.set`'s value records.
static int put_uv(unsigned char *buf, size_t *used, size_t cap, unsigned long v) {
    for (;;) {
        if (*used >= cap) return 0;
        unsigned char b = (unsigned char)(v & 0x7f);
        v >>= 7;
        if (v) { buf[(*used)++] = b | 0x80; } else { buf[(*used)++] = b; return 1; }
    }
}
static int put_rec(unsigned char *buf, size_t *used, size_t cap, const char *s, size_t n) {
    if (!put_uv(buf, used, cap, (unsigned long)n)) return 0;
    if (*used + n > cap) return 0;
    memcpy(buf + *used, s, n);
    *used += n;
    return 1;
}

// weft.bind(scope, key, intention | [intentions]) — the third argument is one
// intention or an authored first-applicable fallback list (doc/configuration.md
// §5.2). Both shapes cross as the same framed list; a string is a one-entry one.
static JSValue js_bind_key(JSContext *ctx, JSValueConst this_val,
                           int argc, JSValueConst *argv) {
    if (argc < 3) return JS_ThrowTypeError(ctx, "bind(scope, key, cmd | [cmd, ...])");
    size_t ml, kl;
    const char *m = JS_ToCStringLen(ctx, &ml, argv[0]);
    const char *k = JS_ToCStringLen(ctx, &kl, argv[1]);
    static unsigned char buf[4096];
    size_t used = 0;
    int ok = 1;
    JSValue err = JS_UNDEFINED;
    if (m && k) {
        if (JS_IsArray(argv[2])) {
            JSValue lenv = JS_GetPropertyStr(ctx, argv[2], "length");
            uint32_t len = 0;
            JS_ToUint32(ctx, &len, lenv);
            JS_FreeValue(ctx, lenv);
            if (len == 0 || len > WEFT_BIND_MAX_CMDS)
                err = JS_ThrowRangeError(ctx, "bind fallback list holds 1 to %d intentions", WEFT_BIND_MAX_CMDS);
            else
                ok = put_uv(buf, &used, sizeof buf, len);
            for (uint32_t i = 0; ok && !JS_IsException(err) && i < len; i++) {
                JSValue ev = JS_GetPropertyUint32(ctx, argv[2], i);
                if (!JS_IsString(ev)) {
                    err = JS_ThrowTypeError(ctx, "bind fallback entries must be strings");
                    JS_FreeValue(ctx, ev);
                    break;
                }
                size_t el;
                const char *es = JS_ToCStringLen(ctx, &el, ev);
                if (es) ok = put_rec(buf, &used, sizeof buf, es, el);
                JS_FreeCString(ctx, es);
                JS_FreeValue(ctx, ev);
            }
        } else {
            size_t cl;
            const char *c = JS_ToCStringLen(ctx, &cl, argv[2]);
            ok = c && put_uv(buf, &used, sizeof buf, 1) &&
                 put_rec(buf, &used, sizeof buf, c, cl);
            JS_FreeCString(ctx, c);
        }
        if (ok && !JS_IsException(err)) host_bind_key(m, (int)ml, k, (int)kl, (const char *)buf, (int)used);
    }
    JS_FreeCString(ctx, m);
    JS_FreeCString(ctx, k);
    return err;
}

static JSValue js_run(JSContext *ctx, JSValueConst this_val,
                      int argc, JSValueConst *argv) {
    if (argc < 1 || argc > WEFT_RUN_MAX_ARGS + 1)
        return JS_ThrowTypeError(ctx, "run(cmd, ...stringArgs): at most 8 args");
    size_t cl;
    const char *c = JS_ToCStringLen(ctx, &cl, argv[0]);
    if (!c) return JS_EXCEPTION;
    if (cl > WEFT_RUN_MAX_ARG_BYTES) {
        JS_FreeCString(ctx, c);
        return JS_ThrowRangeError(ctx, "run command name is too large");
    }
    WeftRunArg args[WEFT_RUN_MAX_ARGS];
    int total = 0;
    int converted = 0;
    for (int i = 1; i < argc; ++i) {
        if (!JS_IsString(argv[i])) {
            for (int j = 0; j < converted; ++j) JS_FreeCString(ctx, args[j].ptr);
            JS_FreeCString(ctx, c);
            return JS_ThrowTypeError(ctx, "run arguments must be strings");
        }
        size_t len;
        const char *arg = JS_ToCStringLen(ctx, &len, argv[i]);
        if (!arg) {
            for (int j = 0; j < converted; ++j) JS_FreeCString(ctx, args[j].ptr);
            JS_FreeCString(ctx, c);
            return JS_EXCEPTION;
        }
        if (len > WEFT_RUN_MAX_ARG_BYTES || total > WEFT_RUN_MAX_TOTAL_BYTES - (int)len) {
            JS_FreeCString(ctx, arg);
            for (int j = 0; j < converted; ++j) JS_FreeCString(ctx, args[j].ptr);
            JS_FreeCString(ctx, c);
            return JS_ThrowRangeError(ctx, "run argument payload is too large");
        }
        args[converted++] = (WeftRunArg){ .ptr = arg, .len = (int)len };
        total += (int)len;
    }
    host_run(c, (int)cl, args, converted);
    for (int i = 0; i < converted; ++i) JS_FreeCString(ctx, args[i].ptr);
    JS_FreeCString(ctx, c);
    return JS_UNDEFINED;
}

// weft.use(name): a shared-defaults include, so the pick / editing / menu-nav
// key bindings live in config data (a defaults.js every config includes), not
// imperatively in core. The host does the whole nested evaluation now (its
// own fresh quickjs runtime, producing an IMPORTED sub-manifest at its own
// tier — north-star-plan §2.2/§2.3) — no nested JS_Eval in this runtime, so a
// broken include can't leave half of ITS declarations applied into a shared
// JS global scope.
static JSValue js_use(JSContext *ctx, JSValueConst this_val,
                      int argc, JSValueConst *argv) {
    if (argc < 1) return JS_UNDEFINED;
    size_t nl;
    const char *name = JS_ToCStringLen(ctx, &nl, argv[0]);
    if (!name) return JS_UNDEFINED;
    host_use(name, (int)nl);
    JS_FreeCString(ctx, name);
    return JS_UNDEFINED;
}

static JSValue js_echo(JSContext *ctx, JSValueConst this_val,
                       int argc, JSValueConst *argv) {
    if (argc < 1) return JS_UNDEFINED;
    size_t l;
    const char *s = JS_ToCStringLen(ctx, &l, argv[0]);
    if (s) host_echo(s, (int)l);
    JS_FreeCString(ctx, s);
    return JS_UNDEFINED;
}

static JSValue js_log(JSContext *ctx, JSValueConst this_val,
                      int argc, JSValueConst *argv) {
    if (argc < 1) return JS_UNDEFINED;
    size_t l;
    const char *s = JS_ToCStringLen(ctx, &l, argv[0]);
    if (s) host_log(s, (int)l);
    JS_FreeCString(ctx, s);
    return JS_UNDEFINED;
}

// Load a plugin by name (resolved against the host's plugin dir) or path.
// Synchronous: the plugin's commands are registered by the time this returns,
// so a following weft.bind can reference them.
static JSValue js_plugin(JSContext *ctx, JSValueConst this_val,
                         int argc, JSValueConst *argv) {
    if (argc < 1) return JS_ThrowTypeError(ctx, "plugin(name)");
    size_t l;
    const char *s = JS_ToCStringLen(ctx, &l, argv[0]);
    if (s) host_plugin(s, (int)l);
    JS_FreeCString(ctx, s);
    return JS_UNDEFINED;
}

// ── weft.set(plugin, key, value) hands a plugin a small declarative table
// (its keymap, pairs, formatters, languages) that overrides the plugin's
// shipped defaults. `value` is a string (one record) or an array of strings
// (records), framed by put_uv/put_rec above. ──

static JSValue js_set(JSContext *ctx, JSValueConst this_val,
                      int argc, JSValueConst *argv) {
    if (argc < 3) return JS_ThrowTypeError(ctx, "set(plugin, key, value)");
    size_t pl, kl;
    const char *p = JS_ToCStringLen(ctx, &pl, argv[0]);
    const char *k = JS_ToCStringLen(ctx, &kl, argv[1]);
    static unsigned char buf[65536];
    size_t used = 0;
    int ok = 1;
    if (p && k) {
        if (JS_IsArray(argv[2])) {
            JSValue lenv = JS_GetPropertyStr(ctx, argv[2], "length");
            uint32_t len = 0;
            JS_ToUint32(ctx, &len, lenv);
            JS_FreeValue(ctx, lenv);
            ok = put_uv(buf, &used, sizeof buf, len);
            for (uint32_t i = 0; ok && i < len; i++) {
                JSValue ev = JS_GetPropertyUint32(ctx, argv[2], i);
                size_t el;
                const char *es = JS_ToCStringLen(ctx, &el, ev);
                if (es) ok = put_rec(buf, &used, sizeof buf, es, el);
                JS_FreeCString(ctx, es);
                JS_FreeValue(ctx, ev);
            }
        } else {
            size_t vl;
            const char *vs = JS_ToCStringLen(ctx, &vl, argv[2]);
            ok = put_uv(buf, &used, sizeof buf, 1);
            if (ok && vs) ok = put_rec(buf, &used, sizeof buf, vs, vl);
            JS_FreeCString(ctx, vs);
        }
        if (ok) host_set(p, (int)pl, k, (int)kl, (const char *)buf, (int)used);
    }
    JS_FreeCString(ctx, p);
    JS_FreeCString(ctx, k);
    return JS_UNDEFINED;
}

// weft.menu(name) — declare a prefix-menu keymap mode (a which-key submenu). A
// leader key bound to `name` (a menu mode) enters it; the menu swallows text and
// Escape/C-g leave it. This is what makes the doom-style leader tree config, not
// baked into a plugin.
static JSValue js_menu(JSContext *ctx, JSValueConst this_val,
                       int argc, JSValueConst *argv) {
    if (argc < 1) return JS_ThrowTypeError(ctx, "menu(name)");
    size_t l;
    const char *s = JS_ToCStringLen(ctx, &l, argv[0]);
    if (s) host_menu(s, (int)l);
    JS_FreeCString(ctx, s);
    return JS_UNDEFINED;
}

// weft.group(scope, prefix, name) — label an implicit chord group. The label
// is presentation metadata; the prefix remains an ordinary key sequence.
static JSValue js_group(JSContext *ctx, JSValueConst this_val,
                        int argc, JSValueConst *argv) {
    if (argc < 3) return JS_ThrowTypeError(ctx, "group(scope, prefix, name)");
    size_t ml, pl, nl;
    const char *mode = JS_ToCStringLen(ctx, &ml, argv[0]);
    const char *prefix = JS_ToCStringLen(ctx, &pl, argv[1]);
    const char *name = JS_ToCStringLen(ctx, &nl, argv[2]);
    if (mode && prefix && name) host_group(mode, (int)ml, prefix, (int)pl, name, (int)nl);
    JS_FreeCString(ctx, mode);
    JS_FreeCString(ctx, prefix);
    JS_FreeCString(ctx, name);
    return JS_UNDEFINED;
}

// weft.action(name) — declare an abstract intent a key can bind to; providers
// registered with weft.provide resolve it by context at fire time. Policy is
// `pick` (the config plane drives synchronous, command-shaped actions).
// ── A command's presentation, as the shared text form ───────────────────
// One `key\tvalue\n` line per field that is set (`weft_membrane.presentation`
// is the one reader). String fields are taken as written; a tab or newline
// in one would break the form, so such a value is dropped. `with_summary`
// says whether `summary` belongs here: config describes it, while a plugin's
// command declares its summary through `declare_command_doc`.
static const char *const meta_string_keys[] = { "label", "menu", "group", "icon", "toggle" };

static int meta_put(char *out, int cap, int at, const char *key, const char *value, size_t vl) {
    size_t kl = strlen(key);
    if (memchr(value, '\t', vl) || memchr(value, '\n', vl)) return at;
    if (at + (int)(kl + vl + 2) > cap) return at;
    memcpy(out + at, key, kl);
    at += (int)kl;
    out[at++] = '\t';
    memcpy(out + at, value, vl);
    at += (int)vl;
    out[at++] = '\n';
    return at;
}

static int meta_from_object(JSContext *ctx, JSValueConst obj, int with_summary, char *out, int cap) {
    int at = 0;
    if (!JS_IsObject(obj)) return 0;
    for (size_t i = 0; i < sizeof meta_string_keys / sizeof meta_string_keys[0] + 1; i++) {
        const char *key = i < sizeof meta_string_keys / sizeof meta_string_keys[0] ? meta_string_keys[i] : "summary";
        if (!with_summary && strcmp(key, "summary") == 0) continue;
        JSValue v = JS_GetPropertyStr(ctx, obj, key);
        if (JS_IsString(v)) {
            size_t vl;
            const char *s = JS_ToCStringLen(ctx, &vl, v);
            if (s) {
                at = meta_put(out, cap, at, key, s, vl);
                JS_FreeCString(ctx, s);
            }
        }
        JS_FreeValue(ctx, v);
    }
    JSValue order = JS_GetPropertyStr(ctx, obj, "order");
    if (JS_IsNumber(order)) {
        int32_t o = 0;
        if (JS_ToInt32(ctx, &o, order) == 0) {
            char num[16];
            int n = 0;
            uint32_t mag = o < 0 ? (uint32_t)(-(int64_t)o) : (uint32_t)o;
            char rev[12];
            int r = 0;
            do {
                rev[r++] = (char)('0' + mag % 10);
                mag /= 10;
            } while (mag > 0 && r < (int)sizeof rev);
            if (o < 0) num[n++] = '-';
            while (r > 0) num[n++] = rev[--r];
            at = meta_put(out, cap, at, "order", num, (size_t)n);
        }
    }
    JS_FreeValue(ctx, order);
    for (int b = 0; b < 2; b++) {
        const char *key = b == 0 ? "prompts" : "internal";
        JSValue v = JS_GetPropertyStr(ctx, obj, key);
        if (JS_ToBool(ctx, v) > 0) at = meta_put(out, cap, at, key, "on", 2);
        JS_FreeValue(ctx, v);
    }
    return at;
}

// weft.command(id, {label, summary, menu, group, order, icon, prompts, toggle,
// internal}) — the CONFIG plane's: describe how any command is presented,
// whoever registers it and whenever (doc/chrome.md §1.2). A plugin's own
// commands declare theirs through the same fields on `weft.command` in the
// plugin plane; this is the tier that wins over them.
static JSValue js_describe(JSContext *ctx, JSValueConst this_val,
                           int argc, JSValueConst *argv) {
    if (argc < 2 || !JS_IsObject(argv[1]))
        return JS_ThrowTypeError(ctx, "command(id, {label, summary, menu, group, order, icon, prompts, toggle, internal})");
    size_t nl;
    const char *name = JS_ToCStringLen(ctx, &nl, argv[0]);
    if (!name) return JS_EXCEPTION;
    char meta[2048];
    int ml = meta_from_object(ctx, argv[1], 1, meta, (int)sizeof meta);
    host_describe(name, (int)nl, meta, ml);
    JS_FreeCString(ctx, name);
    return JS_UNDEFINED;
}

static JSValue js_action(JSContext *ctx, JSValueConst this_val,
                         int argc, JSValueConst *argv) {
    if (argc < 1) return JS_ThrowTypeError(ctx, "action(name)");
    size_t l;
    const char *s = JS_ToCStringLen(ctx, &l, argv[0]);
    if (s) host_action(s, (int)l);
    JS_FreeCString(ctx, s);
    return JS_UNDEFINED;
}

// weft.semanticAction(name) — declare an open focused structured-view action
// command. The provider/view owns the meaning; config only supplies a keymap
// name and the generic command trampoline.
static JSValue js_semantic_action(JSContext *ctx, JSValueConst this_val,
                                  int argc, JSValueConst *argv) {
    if (argc < 1) return JS_ThrowTypeError(ctx, "semanticAction(name)");
    size_t l;
    const char *s = JS_ToCStringLen(ctx, &l, argv[0]);
    if (s) host_semantic_action(s, (int)l);
    JS_FreeCString(ctx, s);
    return JS_UNDEFINED;
}

// JSON text of `v`, or NULL (with *len 0) when `v` is absent or has no JSON
// form. The caller frees a non-NULL result with JS_FreeCString.
static const char *json_of(JSContext *ctx, JSValueConst v, size_t *len) {
    *len = 0;
    if (JS_IsUndefined(v) || JS_IsNull(v)) return NULL;
    JSValue s = JS_JSONStringify(ctx, v, JS_UNDEFINED, JS_UNDEFINED);
    if (JS_IsException(s) || !JS_IsString(s)) {
        JS_FreeValue(ctx, s);
        return NULL;
    }
    const char *out = JS_ToCStringLen(ctx, len, s);
    JS_FreeValue(ctx, s);
    return out;
}

// weft.provide(action, when, cmd[, prio | opts]) — register a provider for
// `action`. `when` is an object over the context facts — {mode?, lang?, tool?,
// role?, locality?}; an absent field is "don't care". The fourth argument is
// the priority, or an object {priority?, label?, group?, order?} whose other
// fields say how the provider's offer is PRESENTED where it wins. Both cross
// as JSON and are parsed host-side into the same Predicate the wasm door
// builds, so the two planes cannot disagree about what a fact means.
static JSValue js_provide(JSContext *ctx, JSValueConst this_val,
                          int argc, JSValueConst *argv) {
    if (argc < 3) return JS_ThrowTypeError(ctx, "provide(action, when, cmd[, prio | opts])");
    size_t al, cl, wl, ol;
    const char *a = JS_ToCStringLen(ctx, &al, argv[0]);
    const char *c = JS_ToCStringLen(ctx, &cl, argv[2]);
    const char *when = json_of(ctx, argv[1], &wl);
    const char *opts = argc >= 4 ? json_of(ctx, argv[3], &ol) : NULL;
    if (!opts) ol = 0;
    if (a && c)
        host_provide(a, (int)al, when ? when : "", (int)wl, c, (int)cl,
                     opts ? opts : "", (int)ol);
    JS_FreeCString(ctx, a);
    JS_FreeCString(ctx, c);
    if (when) JS_FreeCString(ctx, when);
    if (opts) JS_FreeCString(ctx, opts);
    return JS_UNDEFINED;
}

// weft.statusSegment(text, role[, priority]) — stage a static status-line
// segment (north-star-plan §6 W3, task #19). `role` names a
// core.surface.Role ("normal","muted","accent",…); unknown/empty falls back
// to "normal" host-side. `priority` defaults to 0 — the composition sort key
// within `ui/statusline-seg` (an ordered_union slot). `command`, when given,
// is what a click on the segment runs.
static JSValue js_status_segment(JSContext *ctx, JSValueConst this_val,
                                 int argc, JSValueConst *argv) {
    if (argc < 2) return JS_ThrowTypeError(ctx, "statusSegment(text, role[, priority[, command]])");
    size_t tl, rl, cl = 0;
    const char *txt = JS_ToCStringLen(ctx, &tl, argv[0]);
    const char *role = JS_ToCStringLen(ctx, &rl, argv[1]);
    int32_t prio = 0;
    if (argc >= 3) JS_ToInt32(ctx, &prio, argv[2]);
    const char *cmd = NULL;
    if (argc >= 4 && JS_IsString(argv[3])) cmd = JS_ToCStringLen(ctx, &cl, argv[3]);
    if (txt && role) host_status_segment(txt, (int)tl, role, (int)rl, prio, cmd ? cmd : "", (int)cl);
    JS_FreeCString(ctx, txt);
    JS_FreeCString(ctx, role);
    if (cmd) JS_FreeCString(ctx, cmd);
    return JS_UNDEFINED;
}

// weft.grant(plugin, capability[, opts]) — stage a GrantDecl onto the
// manifest (north-star-plan §6 W4 slice 4). `opts` is a plain object;
// `opts.root`, if a (possibly empty) STRING, narrows the grant to
// Limit.fs_root ("" is a legitimate string value — still unrestricted, same
// as omitting `root` entirely). Omitted `opts`, or an `opts` object with no
// `root` property at all, is the legitimate unrestricted case.
//
// FAIL CLOSED on a mistyped narrowing (review send-back, required close):
// if `opts` IS present and DOES have an own `root` property, but that
// property's VALUE is not a string (`{root: undefined}`, `{root: 123}`, a
// typo'd variable that evaluated to `undefined`, …), this is an ERROR, not
// a silent widen to unrestricted — `{root: someUndefinedVar}` must never
// quietly grant unlimited access. Distinguishing "no root key" (fine, stays
// unrestricted) from "a root key whose value is wrong" (reject) needs
// JS_HasProperty, not just JS_GetPropertyStr — the latter returns
// JS_UNDEFINED for BOTH cases indistinguishably. Sealed eval fails loudly
// (the M3 precedent): a JS_ThrowTypeError here surfaces to the config
// author as a ConfigException at eval time, not a permission silently
// granted wider than intended.
static JSValue js_grant(JSContext *ctx, JSValueConst this_val,
                        int argc, JSValueConst *argv) {
    if (argc < 2) return JS_ThrowTypeError(ctx, "grant(plugin, capability[, opts])");
    size_t pl, cl;
    const char *plugin = JS_ToCStringLen(ctx, &pl, argv[0]);
    const char *capability = JS_ToCStringLen(ctx, &cl, argv[1]);
    const char *root = NULL;
    size_t rl = 0;
    JSValue jroot = JS_UNDEFINED;
    if (argc >= 3 && JS_IsObject(argv[2])) {
        JSAtom root_atom = JS_NewAtom(ctx, "root");
        int has_root = JS_HasProperty(ctx, argv[2], root_atom);
        if (has_root < 0) {
            // JS_HasProperty itself threw (e.g. a Proxy trap) — propagate.
            JS_FreeAtom(ctx, root_atom);
            JS_FreeCString(ctx, plugin);
            JS_FreeCString(ctx, capability);
            return JS_EXCEPTION;
        }
        if (has_root) {
            jroot = JS_GetProperty(ctx, argv[2], root_atom);
            JS_FreeAtom(ctx, root_atom);
            if (!JS_IsString(jroot)) {
                JSValue exc = JS_ThrowTypeError(ctx, "grant(plugin, capability, opts): opts.root must be a string — a non-string/undefined root would silently grant UNRESTRICTED access instead of the narrowing you meant");
                JS_FreeValue(ctx, jroot);
                JS_FreeCString(ctx, plugin);
                JS_FreeCString(ctx, capability);
                return exc;
            }
            root = JS_ToCStringLen(ctx, &rl, jroot);
        } else {
            JS_FreeAtom(ctx, root_atom);
        }
    }
    if (plugin && capability) host_grant(plugin, (int)pl, capability, (int)cl, root ? root : "", (int)rl);
    JS_FreeCString(ctx, plugin);
    JS_FreeCString(ctx, capability);
    if (root) JS_FreeCString(ctx, root);
    JS_FreeValue(ctx, jroot);
    return JS_UNDEFINED;
}

// Read `opts.key` as a boolean, or `dflt` when absent. Config attributes are
// a closed set with real defaults, so an omitted key is the default and a
// present one is whatever it says — no third "unset" state to model.
static int opt_bool(JSContext *ctx, JSValueConst opts, const char *key, int dflt) {
    if (!JS_IsObject(opts)) return dflt;
    JSValue v = JS_GetPropertyStr(ctx, opts, key);
    int out = (JS_IsUndefined(v) || JS_IsNull(v)) ? dflt : JS_ToBool(ctx, v);
    JS_FreeValue(ctx, v);
    return out;
}

// weft.viewport(name, opts) — declare a viewport by its ATTRIBUTES
// (doc/cwa-config-decisions.md D1). `opts.edge` docks it ("left"/"right"/
// "top"/"bottom"; omitted means tiled), `opts.extent` is its share of the
// frame (a number) or `{rows: n}` text rows, and cycles/persistent/
// followFocus/takesFocus/statusLine are the remaining attributes.
// "sidebar" is a fragment that sets these — never a kind this shim knows.
static JSValue js_viewport(JSContext *ctx, JSValueConst this_val,
                           int argc, JSValueConst *argv) {
    if (argc < 1) return JS_ThrowTypeError(ctx, "viewport(name[, opts])");
    size_t nl;
    const char *name = JS_ToCStringLen(ctx, &nl, argv[0]);
    if (!name) return JS_EXCEPTION;
    JSValueConst opts = argc >= 2 ? argv[1] : JS_UNDEFINED;
    const char *edge = NULL;
    size_t el = 0;
    double extent = 0.25;
    int flags = 0;
    int extent_arg = 0;
    JSValue jedge = JS_UNDEFINED, jextent = JS_UNDEFINED;
    if (JS_IsObject(opts)) {
        jedge = JS_GetPropertyStr(ctx, opts, "edge");
        if (JS_IsString(jedge)) edge = JS_ToCStringLen(ctx, &el, jedge);
        jextent = JS_GetPropertyStr(ctx, opts, "extent");
        if (JS_IsObject(jextent)) {
            // `{rows: n}`: whole text rows, resolved to pixels by the layout
            // from the view's row height — never a share of the frame.
            JSValue jrows = JS_GetPropertyStr(ctx, jextent, "rows");
            int32_t rows = 1;
            if (!JS_IsUndefined(jrows) && !JS_IsNull(jrows)) JS_ToInt32(ctx, &rows, jrows);
            JS_FreeValue(ctx, jrows);
            flags |= WEFT_VP_EXTENT_ROWS;
            // 0 is a viewport that is only its status line; the host holds
            // any other viewport to one row.
            extent_arg = rows < 0 ? 0 : rows;
        } else if (!JS_IsUndefined(jextent) && !JS_IsNull(jextent)) {
            JS_ToFloat64(ctx, &extent, jextent);
        }
    }
    if (!(flags & WEFT_VP_EXTENT_ROWS)) extent_arg = (int)(extent * 1000);
    if (opt_bool(ctx, opts, "cycles", 1)) flags |= WEFT_VP_CYCLES;
    if (opt_bool(ctx, opts, "persistent", 0)) flags |= WEFT_VP_PERSISTENT;
    if (opt_bool(ctx, opts, "followFocus", 1)) flags |= WEFT_VP_FOCUS_SOURCE;
    if (opt_bool(ctx, opts, "takesFocus", 1)) flags |= WEFT_VP_TAKES_FOCUS;
    if (opt_bool(ctx, opts, "statusLine", 1)) flags |= WEFT_VP_STATUS_LINE;
    // `shown: false` starts it hidden: a panel opened on demand.
    if (!opt_bool(ctx, opts, "shown", 1)) flags |= WEFT_VP_HIDDEN;
    host_viewport(name, (int)nl, edge ? edge : "", (int)el, flags, extent_arg);
    JS_FreeCString(ctx, name);
    if (edge) JS_FreeCString(ctx, edge);
    JS_FreeValue(ctx, jedge);
    JS_FreeValue(ctx, jextent);
    return JS_UNDEFINED;
}

// One of `present`'s two bindable options: a designation string, or
// `{context: "<key>"}` — the current value of ONE context key. No function,
// no composition: anything else is refused. Sets *key when it is a key; the
// string (owned by the caller) is NULL when the option is absent.
static int present_binding(JSContext *ctx, JSValueConst opts, const char *prop,
                           const char **out, size_t *len, int *key) {
    JSValue v = JS_GetPropertyStr(ctx, opts, prop);
    *out = NULL;
    *len = 0;
    *key = 0;
    int ok = 1;
    if (JS_IsString(v)) {
        *out = JS_ToCStringLen(ctx, len, v);
    } else if (JS_IsObject(v)) {
        JSValue k = JS_GetPropertyStr(ctx, v, "context");
        if (JS_IsString(k)) {
            *out = JS_ToCStringLen(ctx, len, k);
            *key = 1;
        } else {
            ok = 0;
        }
        JS_FreeValue(ctx, k);
    } else if (!JS_IsUndefined(v)) {
        ok = 0;
    }
    JS_FreeValue(ctx, v);
    return ok;
}

// weft.present(viewport, opts) — "present resource R in viewport V" (§7) as
// a declaration. Separate from `viewport` because presenting is an ordinary
// operation on a live viewport, not part of what the viewport is.
// `opts.subject` is a designation or `{context: key}` (followed: presented
// again when the key moves), `opts.as` the projection to show it as, and
// `opts.reveal` a designation or `{context: key}` to highlight inside it.
static JSValue js_present(JSContext *ctx, JSValueConst this_val,
                          int argc, JSValueConst *argv) {
    if (argc < 2 || !JS_IsObject(argv[1]))
        return JS_ThrowTypeError(ctx, "present(viewport, {subject, as, reveal})");
    size_t vl, sl, al = 0, rl;
    const char *vp = JS_ToCStringLen(ctx, &vl, argv[0]);
    if (!vp) return JS_EXCEPTION;
    const char *subject, *reveal, *as = NULL;
    int subject_key, reveal_key;
    int ok = present_binding(ctx, argv[1], "subject", &subject, &sl, &subject_key);
    ok = present_binding(ctx, argv[1], "reveal", &reveal, &rl, &reveal_key) && ok;
    JSValue jas = JS_GetPropertyStr(ctx, argv[1], "as");
    if (JS_IsString(jas)) as = JS_ToCStringLen(ctx, &al, jas);
    else if (!JS_IsUndefined(jas)) ok = 0;
    JSValue result = JS_UNDEFINED;
    if (!ok || !subject) {
        result = JS_ThrowTypeError(ctx, "present(viewport, {subject, as, reveal}): subject and reveal are a designation or {context: \"<key>\"}, and as a name");
    } else {
        host_present(vp, (int)vl, subject, (int)sl, as ? as : "", (int)al,
                     reveal ? reveal : "", (int)rl, subject_key | (reveal_key << 1));
    }
    JS_FreeCString(ctx, vp);
    if (subject) JS_FreeCString(ctx, subject);
    if (reveal) JS_FreeCString(ctx, reveal);
    if (as) JS_FreeCString(ctx, as);
    JS_FreeValue(ctx, jas);
    return result;
}

// Install the `weft` global: the config surface config.js calls.
static void install_weft(JSContext *ctx) {
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue weft = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, weft, "bind", JS_NewCFunction(ctx, js_bind_key, "bind", 3));
    JS_SetPropertyStr(ctx, weft, "run", JS_NewCFunction(ctx, js_run, "run", 1));
    JS_SetPropertyStr(ctx, weft, "use", JS_NewCFunction(ctx, js_use, "use", 1));
    JS_SetPropertyStr(ctx, weft, "echo", JS_NewCFunction(ctx, js_echo, "echo", 1));
    JS_SetPropertyStr(ctx, weft, "log", JS_NewCFunction(ctx, js_log, "log", 1));
    JS_SetPropertyStr(ctx, weft, "plugin", JS_NewCFunction(ctx, js_plugin, "plugin", 1));
    JS_SetPropertyStr(ctx, weft, "set", JS_NewCFunction(ctx, js_set, "set", 3));
    JS_SetPropertyStr(ctx, weft, "menu", JS_NewCFunction(ctx, js_menu, "menu", 1));
    JS_SetPropertyStr(ctx, weft, "group", JS_NewCFunction(ctx, js_group, "group", 3));
    JS_SetPropertyStr(ctx, weft, "action", JS_NewCFunction(ctx, js_action, "action", 1));
    JS_SetPropertyStr(ctx, weft, "command", JS_NewCFunction(ctx, js_describe, "command", 2));
    JS_SetPropertyStr(ctx, weft, "semanticAction", JS_NewCFunction(ctx, js_semantic_action, "semanticAction", 1));
    JS_SetPropertyStr(ctx, weft, "provide", JS_NewCFunction(ctx, js_provide, "provide", 3));
    JS_SetPropertyStr(ctx, weft, "statusSegment", JS_NewCFunction(ctx, js_status_segment, "statusSegment", 2));
    JS_SetPropertyStr(ctx, weft, "grant", JS_NewCFunction(ctx, js_grant, "grant", 2));
    JS_SetPropertyStr(ctx, weft, "viewport", JS_NewCFunction(ctx, js_viewport, "viewport", 2));
    JS_SetPropertyStr(ctx, weft, "present", JS_NewCFunction(ctx, js_present, "present", 2));
    JS_SetPropertyStr(ctx, global, "weft", weft);
    JS_FreeValue(ctx, global);
}

// ── Plugin plane: a PERSISTENT runtime (distinct from the per-eval config
// path above). One quickjs.wasm instance per JS plugin, so these statics are
// per-plugin. The plugin's JS registers command handlers via weft.command and
// the host dispatches them by id through weft_on_command — the same
// describe/init/on_command lifecycle a .wasm plugin has, one layer up. ──
static JSRuntime *g_rt = NULL;
static JSContext *g_ctx = NULL;
static JSValue g_cmds; // JS array: id -> handler fn
static JSValue g_on_output; // handler (handle) => void for proc-stream output
static JSValue g_on_pick; // handler (index) => void for a pick accept
static JSValue g_on_exit; // handler (handle) => void for a proc-stream child exit
static JSValue g_on_context_changed; // handler (keys) => void, at the frame boundary
static JSValue g_on_subject_changed; // handler (designation) => void, bound to the subject

// weft.command(name, fn, summary?, params?): register a command and remember
// its handler by the host-assigned id.
//
// `summary` and `params` are what a `.wasm` plugin's `CommandEntry` carries and
// mean exactly the same: one line saying what this command IS, and the
// parameter list a palette shows and asks for. They go through the same host
// body its declaration does, so there is one definition of what a command
// declaration is rather than one per plane.
//
// Left out, the command is UNDOCUMENTED — the same standing a bare `.wasm`
// entry has. It used to be registered with the literal string "js", which is
// not a summary: it named the plane, and the plane is what the command's OWNER
// already says.
// The options form, `weft.command(name, fn, {summary, params, arity, label,
// menu, group, order, icon, prompts, toggle, internal})`, carries a command's
// presentation too (doc/chrome.md §1.2) — the same fields a `.wasm` plugin's
// `CommandEntry` has, through the same declare bodies.
static const char *opt_string(JSContext *ctx, JSValueConst obj, const char *key, size_t *len) {
    JSValue v = JS_GetPropertyStr(ctx, obj, key);
    const char *s = JS_IsUndefined(v) ? NULL : JS_ToCStringLen(ctx, len, v);
    JS_FreeValue(ctx, v);
    return s;
}

static JSValue js_command(JSContext *ctx, JSValueConst this_val,
                          int argc, JSValueConst *argv) {
    if (argc < 2 || !JS_IsFunction(ctx, argv[1]))
        return JS_ThrowTypeError(ctx, "command(name, fn[, summary[, params[, arity]]] | {summary, params, arity, label, …})");
    size_t nl;
    const char *name = JS_ToCStringLen(ctx, &nl, argv[0]);
    if (!name) return JS_EXCEPTION;
    size_t sl = 0, pl = 0, al = 0;
    const int opts = argc >= 3 && JS_IsObject(argv[2]) && !JS_IsFunction(ctx, argv[2]);
    const char *summary = opts ? opt_string(ctx, argv[2], "summary", &sl)
                          : argc >= 3 && !JS_IsUndefined(argv[2]) ? JS_ToCStringLen(ctx, &sl, argv[2]) : NULL;
    const char *params = opts ? opt_string(ctx, argv[2], "params", &pl)
                         : argc >= 4 && !JS_IsUndefined(argv[3]) ? JS_ToCStringLen(ctx, &pl, argv[3]) : NULL;
    // `arity` — "each", "whole" or "homogeneous" — is how the command maps
    // over several selections. Left out, it is undeclared, and dispatch
    // refuses it on several selections rather than guess.
    const char *arity = opts ? opt_string(ctx, argv[2], "arity", &al)
                        : argc >= 5 && !JS_IsUndefined(argv[4]) ? JS_ToCStringLen(ctx, &al, argv[4]) : NULL;
    if (summary || params || arity)
        host_declare_command_doc(name, (int)nl, params ? params : "", (int)pl,
                                 summary ? summary : "", (int)sl);
    if (arity) {
        int code = -1;
        if (al == 4 && memcmp(arity, "each", 4) == 0) code = 0;
        else if (al == 5 && memcmp(arity, "whole", 5) == 0) code = 1;
        else if (al == 11 && memcmp(arity, "homogeneous", 11) == 0) code = 2;
        if (code >= 0) host_declare_arity(name, (int)nl, code, "", 0);
        JS_FreeCString(ctx, arity);
    }
    if (opts) {
        char meta[2048];
        int ml = meta_from_object(ctx, argv[2], 0, meta, (int)sizeof meta);
        if (ml > 0) host_declare_command_meta(name, (int)nl, meta, ml);
    }
    if (summary) JS_FreeCString(ctx, summary);
    if (params) JS_FreeCString(ctx, params);
    int id = host_register(name, (int)nl);
    JS_FreeCString(ctx, name);
    if (id >= 0) JS_SetPropertyUint32(ctx, g_cmds, (uint32_t)id, JS_DupValue(ctx, argv[1]));
    return JS_UNDEFINED;
}

// weft.procSpawn(cmd) -> handle (or -1): a persistent duplex child, run in the
// dispatching entry's PLACE (doc/place.md).
//
// There is deliberately no cwd argument. A JS plugin is not a different kind of
// plugin, and the wasm door (wl_proc_spawn) has none either. A raw directory
// string is also exactly the local-first spelling this design removes: it
// cannot name a peer or a synthetic container, so it could only ever have meant
// "somewhere on this machine", which is the assumption being retired.
// Throws when the plugin holds no `proc` grant.
static JSValue js_proc_spawn(JSContext *ctx, JSValueConst this_val,
                             int argc, JSValueConst *argv) {
    if (argc < 1) return JS_ThrowTypeError(ctx, "procSpawn(cmd)");
    size_t cl;
    const char *cmd = JS_ToCStringLen(ctx, &cl, argv[0]);
    int h = -1;
    if (cmd) h = host_proc_spawn(cmd, (int)cl);
    JS_FreeCString(ctx, cmd);
    if (h == WEFT_DENIED) return weft_throw_denied(ctx, "procSpawn");
    return JS_NewInt32(ctx, h);
}

// weft.procSend(handle, str): write to the child's stdin verbatim.
static JSValue js_proc_send(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv) {
    if (argc < 2) return JS_UNDEFINED;
    int h;
    JS_ToInt32(ctx, &h, argv[0]);
    size_t l;
    const char *s = JS_ToCStringLen(ctx, &l, argv[1]);
    if (s) host_proc_send(h, s, (int)l);
    JS_FreeCString(ctx, s);
    return JS_UNDEFINED;
}

// weft.procRead(handle) -> string: newly-arrived stdout, "" if none. The
// handler loops this to drain, splitting on newlines to recover NDJSON lines.
static char g_read_buf[262144];
static JSValue js_proc_read(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv) {
    if (argc < 1) return JS_NewStringLen(ctx, "", 0);
    int h;
    JS_ToInt32(ctx, &h, argv[0]);
    int n = host_proc_read(h, g_read_buf, (int)sizeof g_read_buf);
    if (n == WEFT_DENIED) return weft_throw_denied(ctx, "procRead");
    if (n <= 0) return JS_NewStringLen(ctx, "", 0);
    return JS_NewStringLen(ctx, g_read_buf, (size_t)n);
}

// weft.procClose(handle): kill + free the child.
static JSValue js_proc_close(JSContext *ctx, JSValueConst this_val,
                             int argc, JSValueConst *argv) {
    if (argc < 1) return JS_UNDEFINED;
    int h;
    JS_ToInt32(ctx, &h, argv[0]);
    host_proc_close(h);
    return JS_UNDEFINED;
}

// weft.bufferAppend(name, text[, class]): append to a named buffer (created if
// absent); `class` is a StyleClass (0 = none) painted over the appended range.
static JSValue js_buffer_append(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv) {
    if (argc < 2) return JS_UNDEFINED;
    size_t nl, tl;
    const char *name = JS_ToCStringLen(ctx, &nl, argv[0]);
    const char *text = JS_ToCStringLen(ctx, &tl, argv[1]);
    int32_t cls = 0;
    if (argc >= 3) JS_ToInt32(ctx, &cls, argv[2]);
    if (name && text) host_buffer_append(name, (int)nl, text, (int)tl, cls);
    JS_FreeCString(ctx, name);
    JS_FreeCString(ctx, text);
    return JS_UNDEFINED;
}

// weft.bufferFold(name, start, end): collapse a range of a named buffer.
static JSValue js_buffer_fold(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv) {
    if (argc < 3) return JS_UNDEFINED;
    size_t nl;
    const char *name = JS_ToCStringLen(ctx, &nl, argv[0]);
    int32_t start = 0, end = 0;
    JS_ToInt32(ctx, &start, argv[1]);
    JS_ToInt32(ctx, &end, argv[2]);
    if (name) host_buffer_fold(name, (int)nl, start, end);
    JS_FreeCString(ctx, name);
    return JS_UNDEFINED;
}

// weft.bufferLen(name) -> int: a named buffer's byte length.
static JSValue js_buffer_len(JSContext *ctx, JSValueConst this_val,
                             int argc, JSValueConst *argv) {
    if (argc < 1) return JS_NewInt32(ctx, 0);
    size_t nl;
    const char *name = JS_ToCStringLen(ctx, &nl, argv[0]);
    int n = name ? host_buffer_len(name, (int)nl) : 0;
    JS_FreeCString(ctx, name);
    return JS_NewInt32(ctx, n);
}

// weft.transcriptEntry(name, role, text): start a new entry in this
// plugin's live transcript model (W6 check-in producer seam).
static JSValue js_transcript_entry(JSContext *ctx, JSValueConst this_val,
                                   int argc, JSValueConst *argv) {
    if (argc < 3) return JS_UNDEFINED;
    size_t nl, rl, tl;
    const char *name = JS_ToCStringLen(ctx, &nl, argv[0]);
    const char *role = JS_ToCStringLen(ctx, &rl, argv[1]);
    const char *text = JS_ToCStringLen(ctx, &tl, argv[2]);
    if (name && role && text) host_transcript_entry(name, (int)nl, role, (int)rl, text, (int)tl);
    JS_FreeCString(ctx, name);
    JS_FreeCString(ctx, role);
    JS_FreeCString(ctx, text);
    return JS_UNDEFINED;
}

// weft.transcriptAppend(name, text): stream a chunk onto the currently-open
// entry's body.
static JSValue js_transcript_append(JSContext *ctx, JSValueConst this_val,
                                    int argc, JSValueConst *argv) {
    if (argc < 2) return JS_UNDEFINED;
    size_t nl, tl;
    const char *name = JS_ToCStringLen(ctx, &nl, argv[0]);
    const char *text = JS_ToCStringLen(ctx, &tl, argv[1]);
    if (name && text) host_transcript_append(name, (int)nl, text, (int)tl);
    JS_FreeCString(ctx, name);
    JS_FreeCString(ctx, text);
    return JS_UNDEFINED;
}

// weft.config(key) -> string: this plugin's config value (weft.set), or "".
static char g_config_buf[8192];
static JSValue js_config(JSContext *ctx, JSValueConst this_val,
                         int argc, JSValueConst *argv) {
    if (argc < 1) return JS_NewStringLen(ctx, "", 0);
    size_t kl;
    const char *key = JS_ToCStringLen(ctx, &kl, argv[0]);
    int n = 0;
    if (key) n = host_config(key, (int)kl, g_config_buf, (int)sizeof g_config_buf);
    JS_FreeCString(ctx, key);
    if (n <= 0) return JS_NewStringLen(ctx, "", 0);
    return JS_NewStringLen(ctx, g_config_buf, (size_t)n);
}

// weft.breakpoints(path) -> string: the file's breakpoint lines as a "l1,l2,…"
// CSV (published by the debug plugin), or "". The DAP client reads this to send
// setBreakpoints so the session stops on the lines you marked in the gutter.
static char g_bp_buf[4096];
static JSValue js_breakpoints(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv) {
    if (argc < 1) return JS_NewStringLen(ctx, "", 0);
    size_t pl;
    const char *path = JS_ToCStringLen(ctx, &pl, argv[0]);
    int n = 0;
    if (path) n = host_breakpoints(path, (int)pl, g_bp_buf, (int)sizeof g_bp_buf);
    JS_FreeCString(ctx, path);
    if (n <= 0) return JS_NewStringLen(ctx, "", 0);
    return JS_NewStringLen(ctx, g_bp_buf, (size_t)n);
}

// weft.fileRead(path) -> string: a file's content (live buffer or disk), "" if
// unreadable. Throws when the plugin holds no `fs_read` grant. Shares
// g_read_buf (large; capped at its size for a first cut).
static JSValue js_file_read(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv) {
    if (argc < 1) return JS_NewStringLen(ctx, "", 0);
    size_t pl;
    const char *path = JS_ToCStringLen(ctx, &pl, argv[0]);
    int n = 0;
    if (path) n = host_file_read(path, (int)pl, g_read_buf, (int)sizeof g_read_buf);
    JS_FreeCString(ctx, path);
    if (n == WEFT_DENIED) return weft_throw_denied(ctx, "fileRead");
    if (n <= 0) return JS_NewStringLen(ctx, "", 0);
    return JS_NewStringLen(ctx, g_read_buf, (size_t)n);
}

// weft.fileWrite(path, content[, agent]): apply a whole-file write as the named
// agent peer's edit (default "agent") — per-conversation attribution.
static JSValue js_file_write(JSContext *ctx, JSValueConst this_val,
                             int argc, JSValueConst *argv) {
    if (argc < 2) return JS_UNDEFINED;
    size_t pl, cl, al = 0;
    const char *path = JS_ToCStringLen(ctx, &pl, argv[0]);
    const char *content = JS_ToCStringLen(ctx, &cl, argv[1]);
    const char *agent = (argc >= 3) ? JS_ToCStringLen(ctx, &al, argv[2]) : NULL;
    int n = 0;
    if (path && content) n = host_file_write(path, (int)pl, content, (int)cl, agent ? agent : "", (int)al);
    JS_FreeCString(ctx, path);
    JS_FreeCString(ctx, content);
    if (agent) JS_FreeCString(ctx, agent);
    if (n == WEFT_DENIED) return weft_throw_denied(ctx, "fileWrite");
    return JS_UNDEFINED;
}

// ── The read surface (weft.cursor/byteLen/slice/lineAt/selection/path/jump) ──
// Each calls the SAME host body a wasm plugin's `wl_*` door calls
// (wasm_host/edit.zig's `read_doors`). They carry no authority — reading the
// entry your own command is dispatching in is not an effect — so none is
// perm-gated on either plane.

// weft.cursor() -> number: the caret's byte offset.
static JSValue js_cursor(JSContext *ctx, JSValueConst this_val,
                         int argc, JSValueConst *argv) {
    (void)this_val; (void)argc; (void)argv;
    return JS_NewInt32(ctx, host_cursor());
}

// weft.byteLen() -> number: the entry's length in bytes.
static JSValue js_byte_len(JSContext *ctx, JSValueConst this_val,
                           int argc, JSValueConst *argv) {
    (void)this_val; (void)argc; (void)argv;
    return JS_NewInt32(ctx, host_byte_len());
}

// weft.slice(start, end) -> string: the bytes in [start, end), clamped by the
// host to the document. Longer than the shared scratch is truncated to it —
// same bound `weft.lineText` and `weft.fileRead` already answer under.
static JSValue js_slice(JSContext *ctx, JSValueConst this_val,
                        int argc, JSValueConst *argv) {
    (void)this_val;
    int32_t start = 0, end = 0;
    if (argc > 0) JS_ToInt32(ctx, &start, argv[0]);
    if (argc > 1) JS_ToInt32(ctx, &end, argv[1]);
    int n = host_slice(start, end, g_config_buf, (int)sizeof g_config_buf);
    if (n <= 0) return JS_NewStringLen(ctx, "", 0);
    return JS_NewStringLen(ctx, g_config_buf, (size_t)n);
}

// weft.lineAt(offset) -> {start, end}: the line containing `offset`.
static JSValue js_line_at(JSContext *ctx, JSValueConst this_val,
                          int argc, JSValueConst *argv) {
    (void)this_val;
    int32_t off = 0;
    if (argc > 0) JS_ToInt32(ctx, &off, argv[0]);
    int pair[2] = {0, 0};
    host_line_at(off, pair);
    JSValue o = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, o, "start", JS_NewInt32(ctx, pair[0]));
    JS_SetPropertyStr(ctx, o, "end", JS_NewInt32(ctx, pair[1]));
    return o;
}

// weft.selection() -> {start, end} | null. Null is "no selection", which is a
// different answer from an empty one and must not read as the same.
static JSValue js_selection(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv) {
    (void)this_val; (void)argc; (void)argv;
    int pair[2] = {0, 0};
    if (!host_selection(pair)) return JS_NULL;
    JSValue o = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, o, "start", JS_NewInt32(ctx, pair[0]));
    JS_SetPropertyStr(ctx, o, "end", JS_NewInt32(ctx, pair[1]));
    return o;
}

// weft.path() -> string | null: the entry's backing file, null when it has
// none (a scratch or tool buffer) — again distinct from "".
static JSValue js_path(JSContext *ctx, JSValueConst this_val,
                       int argc, JSValueConst *argv) {
    (void)this_val; (void)argc; (void)argv;
    int n = host_path(g_config_buf, (int)sizeof g_config_buf);
    if (n < 0) return JS_NULL;
    return JS_NewStringLen(ctx, g_config_buf, (size_t)n);
}

// weft.pointer() -> {kind, button, clicks, ctrl, alt, shift, offset, node,
// focused} | null: where the pointer gesture this command is bound to
// happened. `offset`/`node` are null when the pointer is over no text / no
// scene node. Kinds: "press", "release", "drag", "wheel", "hover".
static JSValue js_pointer(JSContext *ctx, JSValueConst this_val,
                          int argc, JSValueConst *argv) {
    (void)this_val; (void)argc; (void)argv;
    static const char *const kinds[] = {"none", "press", "release", "drag", "wheel", "hover"};
    unsigned w[8] = {0};
    if (!host_pointer(w)) return JS_NULL;
    JSValue o = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, o, "kind", JS_NewString(ctx, w[0] < 6 ? kinds[w[0]] : "none"));
    JS_SetPropertyStr(ctx, o, "button", JS_NewInt32(ctx, (int32_t)w[1]));
    JS_SetPropertyStr(ctx, o, "clicks", JS_NewInt32(ctx, (int32_t)w[2]));
    JS_SetPropertyStr(ctx, o, "ctrl", JS_NewBool(ctx, (w[3] & 1) != 0));
    JS_SetPropertyStr(ctx, o, "alt", JS_NewBool(ctx, (w[3] & 2) != 0));
    JS_SetPropertyStr(ctx, o, "shift", JS_NewBool(ctx, (w[3] & 4) != 0));
    JS_SetPropertyStr(ctx, o, "offset", w[4] == 0xffffffffu ? JS_NULL : JS_NewFloat64(ctx, (double)w[4]));
    JS_SetPropertyStr(ctx, o, "node", (w[7] & 4) ? JS_NewFloat64(ctx, (double)w[6] * 4294967296.0 + (double)w[5]) : JS_NULL);
    JS_SetPropertyStr(ctx, o, "focused", JS_NewBool(ctx, (w[7] & 2) != 0));
    return o;
}

// weft.clipboardSet(text) -> bool: take the system clipboard. Throws without
// the `clipboard` grant.
static JSValue js_clipboard_set(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_FALSE;
    size_t l;
    const char *s = JS_ToCStringLen(ctx, &l, argv[0]);
    if (!s) return JS_EXCEPTION;
    int r = host_clipboard_set(s, (int)l);
    JS_FreeCString(ctx, s);
    if (r == WEFT_DENIED) return weft_throw_denied(ctx, "clipboardSet");
    return JS_NewBool(ctx, r == 0);
}

// weft.clipboardGet() -> string | null: the system clipboard's text. Throws
// without the `clipboard` grant; null when it cannot be read.
static JSValue js_clipboard_get(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv) {
    (void)this_val; (void)argc; (void)argv;
    int n = host_clipboard_get(g_read_buf, (int)sizeof g_read_buf);
    if (n == WEFT_DENIED) return weft_throw_denied(ctx, "clipboardGet");
    if (n < 0) return JS_NULL;
    if ((size_t)n <= sizeof g_read_buf) return JS_NewStringLen(ctx, g_read_buf, (size_t)n);
    char *big = js_malloc(ctx, (size_t)n);
    if (!big) return JS_EXCEPTION;
    int m = host_clipboard_get(big, n);
    JSValue v = m < 0 ? JS_NULL : JS_NewStringLen(ctx, big, (size_t)(m < n ? m : n));
    js_free(ctx, big);
    return v;
}

// weft.contextSet(key, value, scope[, place]) -> bool: publish `value` for
// the namespaced `key` ("repl.session") at `scope` — "entry", "place" or
// "global" — of the entry this call is about; at "place", an optional
// `place` designation (`weft://here/dir/…`) names the place instead of the
// calling entry's. An empty value retracts; so does unloading the plugin.
// False when refused (a bad key, scope or place, or another plugin holds the
// key there).
static JSValue js_context_set(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 3) return JS_FALSE;
    const char *scope = JS_ToCString(ctx, argv[2]);
    if (!scope) return JS_EXCEPTION;
    int kind = strcmp(scope, "entry") == 0 ? 0 : strcmp(scope, "place") == 0 ? 1 : strcmp(scope, "global") == 0 ? 2 : -1;
    JS_FreeCString(ctx, scope);
    if (kind < 0) return JS_FALSE;
    size_t kl, vl, pl = 0;
    const char *k = JS_ToCStringLen(ctx, &kl, argv[0]);
    if (!k) return JS_EXCEPTION;
    const char *v = JS_ToCStringLen(ctx, &vl, argv[1]);
    if (!v) {
        JS_FreeCString(ctx, k);
        return JS_EXCEPTION;
    }
    const char *place = "";
    if (argc > 3 && !JS_IsUndefined(argv[3])) {
        place = JS_ToCStringLen(ctx, &pl, argv[3]);
        if (!place) {
            JS_FreeCString(ctx, k);
            JS_FreeCString(ctx, v);
            return JS_EXCEPTION;
        }
    }
    int r = host_context_set(k, (int)kl, v, (int)vl, kind, place, (int)pl);
    JS_FreeCString(ctx, k);
    JS_FreeCString(ctx, v);
    if (argc > 3 && !JS_IsUndefined(argv[3])) JS_FreeCString(ctx, place);
    return JS_NewBool(ctx, r == 0);
}

// weft.contextGet(key) -> string | null: the PRIMARY context's value for any
// key, builtin ("mode", "entry") or published ("repl.session").
static JSValue js_context_get(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_NULL;
    size_t kl;
    const char *k = JS_ToCStringLen(ctx, &kl, argv[0]);
    if (!k) return JS_EXCEPTION;
    int n = host_context_get(k, (int)kl, g_read_buf, (int)sizeof g_read_buf);
    JSValue v;
    if (n < 0) {
        v = JS_NULL;
    } else if ((size_t)n <= sizeof g_read_buf) {
        v = JS_NewStringLen(ctx, g_read_buf, (size_t)n);
    } else {
        char *big = js_malloc(ctx, (size_t)n);
        if (!big) {
            JS_FreeCString(ctx, k);
            return JS_EXCEPTION;
        }
        int m = host_context_get(k, (int)kl, big, n);
        v = m < 0 ? JS_NULL : JS_NewStringLen(ctx, big, (size_t)(m < n ? m : n));
        js_free(ctx, big);
    }
    JS_FreeCString(ctx, k);
    return v;
}

// A host string read through `f(out, cap) -> full length | -1`: grown to the
// full length when `g_read_buf` was short. JS null for -1.
static JSValue read_host_string(JSContext *ctx, int (*f)(char *, int)) {
    int n = f(g_read_buf, (int)sizeof g_read_buf);
    if (n < 0) return JS_NULL;
    if ((size_t)n <= sizeof g_read_buf) return JS_NewStringLen(ctx, g_read_buf, (size_t)n);
    char *big = js_malloc(ctx, (size_t)n);
    if (!big) return JS_EXCEPTION;
    int m = f(big, n);
    JSValue v = m < 0 ? JS_NULL : JS_NewStringLen(ctx, big, (size_t)(m < n ? m : n));
    js_free(ctx, big);
    return v;
}

// A host list read through `f` (one item per line) as a JS array of strings;
// empty for none.
static JSValue read_host_lines(JSContext *ctx, int (*f)(char *, int)) {
    JSValue s = read_host_string(ctx, f);
    JSValue arr = JS_NewArray(ctx);
    if (JS_IsException(s)) {
        JS_FreeValue(ctx, arr);
        return s;
    }
    if (JS_IsNull(s)) return arr;
    size_t len;
    const char *text = JS_ToCStringLen(ctx, &len, s);
    JS_FreeValue(ctx, s);
    if (!text) {
        JS_FreeValue(ctx, arr);
        return JS_EXCEPTION;
    }
    uint32_t i = 0;
    size_t start = 0;
    for (size_t at = 0; len > 0 && at <= len; at++) {
        if (at == len || text[at] == '\n') {
            JS_SetPropertyUint32(ctx, arr, i++, JS_NewStringLen(ctx, text + start, at - start));
            start = at + 1;
        }
    }
    JS_FreeCString(ctx, text);
    return arr;
}

// weft.places() -> string[]: the places the workspace is working in — every
// open entry's place, then every tree a peer shares — as designations.
static JSValue js_places(JSContext *ctx, JSValueConst this_val,
                         int argc, JSValueConst *argv) {
    (void)this_val; (void)argc; (void)argv;
    return read_host_lines(ctx, host_places);
}

// weft.subjectWatch(designation[, watching = true]) -> bool: hear
// weft.onSubjectChanged whenever the entry opening `designation` reads
// differently (an edit, a parse that landed); `false` stops.
static JSValue js_subject_watch(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_FALSE;
    int watching = argc < 2 || JS_ToBool(ctx, argv[1]);
    size_t l;
    const char *s = JS_ToCStringLen(ctx, &l, argv[0]);
    if (!s) return JS_EXCEPTION;
    int r = host_subject_watch(s, (int)l, watching);
    JS_FreeCString(ctx, s);
    return JS_NewBool(ctx, r == 0);
}

// weft.onContextChanged(fn): `fn(keys)` hears which keys of the primary
// context moved — at most once per frame, never inside a dispatch. The host
// is told, so a plugin that never installs one is never called for it;
// `weft.onContextChanged(null)` takes it back.
static JSValue js_on_context_changed(JSContext *ctx, JSValueConst this_val,
                                     int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_UNDEFINED;
    const int listen = JS_IsFunction(ctx, argv[0]);
    if (!listen && !JS_IsNull(argv[0]) && !JS_IsUndefined(argv[0])) return JS_UNDEFINED;
    JS_FreeValue(ctx, g_on_context_changed);
    g_on_context_changed = listen ? JS_DupValue(ctx, argv[0]) : JS_UNDEFINED;
    host_context_listen(listen);
    return JS_UNDEFINED;
}

// weft.onSubjectChanged(fn): `fn(designation)` hears a watched subject read
// differently; during the call every read is the subject's.
static JSValue js_on_subject_changed(JSContext *ctx, JSValueConst this_val,
                                     int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1 || !JS_IsFunction(ctx, argv[0])) return JS_UNDEFINED;
    JS_FreeValue(ctx, g_on_subject_changed);
    g_on_subject_changed = JS_DupValue(ctx, argv[0]);
    return JS_UNDEFINED;
}

// weft.toolBacking(name): mark an entry this plugin made as its tool projection.
static JSValue js_tool_backing(JSContext *ctx, JSValueConst this_val,
                               int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_UNDEFINED;
    size_t l;
    const char *s = JS_ToCStringLen(ctx, &l, argv[0]);
    if (!s) return JS_EXCEPTION;
    host_tool_backing(s, (int)l);
    JS_FreeCString(ctx, s);
    return JS_UNDEFINED;
}

// weft.designation() -> string | null: the designation of the entry this call
// is about.
static JSValue js_designation(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv) {
    (void)this_val; (void)argc; (void)argv;
    return read_host_string(ctx, host_designation);
}

// weft.designate(text) -> bool: declare what an entry this plugin made
// represents — `weft://here/proc/<name>…`, or a projection kind it claimed;
// "" clears. False when refused.
static JSValue js_designate(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_FALSE;
    size_t l;
    const char *s = JS_ToCStringLen(ctx, &l, argv[0]);
    if (!s) return JS_EXCEPTION;
    int r = host_designate(s, (int)l);
    JS_FreeCString(ctx, s);
    return JS_NewBool(ctx, r == 0);
}

// weft.designationOpener(kind, command) -> bool: claim projection kind `kind`
// (the plugin's own name, or under it), re-run by `command` with the
// designation. A refused claim while the plugin loads fails the load.
static JSValue js_designation_opener(JSContext *ctx, JSValueConst this_val,
                                     int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 2) return JS_FALSE;
    size_t kl, cl;
    const char *k = JS_ToCStringLen(ctx, &kl, argv[0]);
    if (!k) return JS_EXCEPTION;
    const char *c = JS_ToCStringLen(ctx, &cl, argv[1]);
    if (!c) {
        JS_FreeCString(ctx, k);
        return JS_EXCEPTION;
    }
    int r = host_designation_opener(k, (int)kl, c, (int)cl);
    JS_FreeCString(ctx, k);
    JS_FreeCString(ctx, c);
    return JS_NewBool(ctx, r == 0);
}

// weft.jumpPush(): remember the caret as a jump in the head's jumplist.
static JSValue js_jump_push(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv) {
    (void)ctx; (void)this_val; (void)argc; (void)argv;
    host_jump_push();
    return JS_UNDEFINED;
}

// weft.macroRecording() -> string | null: the register a macro is recording
// into, for a status chip.
static JSValue js_macro_recording(JSContext *ctx, JSValueConst this_val,
                                  int argc, JSValueConst *argv) {
    (void)this_val; (void)argc; (void)argv;
    int r = host_macro_recording();
    if (r <= 0) return JS_NULL;
    char c = (char)r;
    return JS_NewStringLen(ctx, &c, 1);
}

// weft.jump(offset): move the caret, clamped by the host.
static JSValue js_jump(JSContext *ctx, JSValueConst this_val,
                       int argc, JSValueConst *argv) {
    (void)this_val;
    int32_t off = 0;
    if (argc > 0) JS_ToInt32(ctx, &off, argv[0]);
    host_jump(off);
    return JS_UNDEFINED;
}

// weft.lineText() -> string: the active buffer's current line (a prompt line).
static JSValue js_line_text(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv) {
    (void)argc;
    (void)argv;
    int n = host_line_text(g_config_buf, (int)sizeof g_config_buf);
    if (n <= 0) return JS_NewStringLen(ctx, "", 0);
    return JS_NewStringLen(ctx, g_config_buf, (size_t)n);
}

// weft.activeBuffer() -> string: the focused buffer's display name, "" if none.
// An instanced tool routes a command to the session owning that buffer.
static JSValue js_active_buffer(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv) {
    (void)argc;
    (void)argv;
    int n = host_active_buffer(g_config_buf, (int)sizeof g_config_buf);
    if (n <= 0) return JS_NewStringLen(ctx, "", 0);
    return JS_NewStringLen(ctx, g_config_buf, (size_t)n);
}

// weft.onOutput(fn): register the handler the host fires (with a stream handle)
// when that stream has new bytes to read.
static JSValue js_on_output(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv) {
    if (argc < 1 || !JS_IsFunction(ctx, argv[0])) return JS_UNDEFINED;
    JS_FreeValue(ctx, g_on_output);
    g_on_output = JS_DupValue(ctx, argv[0]);
    return JS_UNDEFINED;
}

// weft.onExit(fn): register the handler the host fires (with a stream handle)
// when that stream's child is gone — announced once, after its last bytes.
static JSValue js_on_exit(JSContext *ctx, JSValueConst this_val,
                          int argc, JSValueConst *argv) {
    if (argc < 1 || !JS_IsFunction(ctx, argv[0])) return JS_UNDEFINED;
    JS_FreeValue(ctx, g_on_exit);
    g_on_exit = JS_DupValue(ctx, argv[0]);
    return JS_UNDEFINED;
}

// weft.pick(prompt, options, token): options is a newline-joined list. Empty
// rows are retained, so the candidate index is the original line ordinal. The
// handler receives one object describing candidate/input/cancelled acceptance,
// carrying `token` (optional, "" when omitted) back untouched.
static JSValue js_pick(JSContext *ctx, JSValueConst this_val,
                       int argc, JSValueConst *argv) {
    if (argc < 2) return JS_UNDEFINED;
    size_t pl, ol, tl = 0;
    const char *prompt = JS_ToCStringLen(ctx, &pl, argv[0]);
    const char *opts = JS_ToCStringLen(ctx, &ol, argv[1]);
    const char *token = argc > 2 ? JS_ToCStringLen(ctx, &tl, argv[2]) : NULL;
    if (prompt && opts)
        host_pick(prompt, (int)pl, opts, (int)ol, token ? token : "", (int)tl);
    JS_FreeCString(ctx, prompt);
    JS_FreeCString(ctx, opts);
    JS_FreeCString(ctx, token);
    return JS_UNDEFINED;
}

// weft.status(text): set the status-line chip ("" clears it).
static JSValue js_status(JSContext *ctx, JSValueConst this_val,
                         int argc, JSValueConst *argv) {
    if (argc < 1) return JS_UNDEFINED;
    size_t l;
    const char *s = JS_ToCStringLen(ctx, &l, argv[0]);
    if (s) host_status(s, (int)l);
    JS_FreeCString(ctx, s);
    return JS_UNDEFINED;
}

// weft.commandMeta(name) -> {label, summary, menu, group, order, icon,
// prompts, toggle, internal} | undefined: how a command, action or intention
// is presented HERE — the answer every UI reads (`wl_command_meta`).
static JSValue js_command_meta(JSContext *ctx, JSValueConst this_val,
                               int argc, JSValueConst *argv) {
    if (argc < 1) return JS_UNDEFINED;
    size_t nl;
    const char *name = JS_ToCStringLen(ctx, &nl, argv[0]);
    if (!name) return JS_EXCEPTION;
    static char buf[4096];
    int n = host_command_meta(name, (int)nl, buf, (int)sizeof buf);
    JS_FreeCString(ctx, name);
    if (n < 0 || n > (int)sizeof buf) return JS_UNDEFINED;
    JSValue obj = JS_NewObject(ctx);
    int at = 0;
    while (at < n) {
        char *nl_at = memchr(buf + at, '\n', (size_t)(n - at));
        int end = nl_at ? (int)(nl_at - buf) : n;
        char *tab = memchr(buf + at, '\t', (size_t)(end - at));
        if (tab) {
            char key[16];
            int kl = (int)(tab - (buf + at));
            if (kl < (int)sizeof key) {
                memcpy(key, buf + at, (size_t)kl);
                key[kl] = 0;
                const char *value = tab + 1;
                int vl = end - (int)(value - buf);
                if (strcmp(key, "order") == 0) {
                    char num[16];
                    int cl = vl < 15 ? vl : 15;
                    memcpy(num, value, (size_t)cl);
                    num[cl] = 0;
                    JS_SetPropertyStr(ctx, obj, key, JS_NewInt32(ctx, atoi(num)));
                } else if (strcmp(key, "prompts") == 0 || strcmp(key, "internal") == 0) {
                    JS_SetPropertyStr(ctx, obj, key, JS_NewBool(ctx, vl == 2 && memcmp(value, "on", 2) == 0));
                } else {
                    JS_SetPropertyStr(ctx, obj, key, JS_NewStringLen(ctx, value, (size_t)vl));
                }
            }
        }
        at = end + 1;
    }
    return obj;
}

// weft.keysFor(name) -> [key, …]: the keys that run a command, action or
// intention where the person is, shortest first, as a person reads them
// (`wl_keys_for`).
static JSValue js_keys_for(JSContext *ctx, JSValueConst this_val,
                           int argc, JSValueConst *argv) {
    JSValue arr = JS_NewArray(ctx);
    if (argc < 1) return arr;
    size_t nl;
    const char *name = JS_ToCStringLen(ctx, &nl, argv[0]);
    if (!name) return arr;
    static char buf[1024];
    int n = host_keys_for(name, (int)nl, buf, (int)sizeof buf);
    JS_FreeCString(ctx, name);
    if (n <= 0 || n > (int)sizeof buf) return arr;
    int at = 0;
    uint32_t i = 0;
    while (at < n) {
        char *nl_at = memchr(buf + at, '\n', (size_t)(n - at));
        int end = nl_at ? (int)(nl_at - buf) : n;
        JS_SetPropertyUint32(ctx, arr, i++, JS_NewStringLen(ctx, buf + at, (size_t)(end - at)));
        at = end + 1;
    }
    return arr;
}

// weft.onPick(fn): register the handler fired with a structured pick outcome.
static JSValue js_on_pick(JSContext *ctx, JSValueConst this_val,
                          int argc, JSValueConst *argv) {
    if (argc < 1 || !JS_IsFunction(ctx, argv[0])) return JS_UNDEFINED;
    JS_FreeValue(ctx, g_on_pick);
    g_on_pick = JS_DupValue(ctx, argv[0]);
    return JS_UNDEFINED;
}

static void log_exception(JSContext *ctx) {
    JSValue exc = JS_GetException(ctx);
    const char *msg = JS_ToCString(ctx, exc);
    if (msg) {
        host_log(msg, (int)strlen(msg));
        JS_FreeCString(ctx, msg);
    }
    JS_FreeValue(ctx, exc);
}

// weft_plugin_init(src, len): stand up the persistent runtime, install the
// weft globals + weft.command, and eval the plugin body (which registers its
// commands and does setup — the describe()+init() of a JS plugin). 0 / -1.
__attribute__((export_name("weft_plugin_init")))
int weft_plugin_init(const char *src, int len) {
    if (g_rt) return -1; // one plugin per instance
    g_rt = JS_NewRuntime();
    if (!g_rt) return -1;
    g_ctx = JS_NewContext(g_rt);
    if (!g_ctx) {
        JS_FreeRuntime(g_rt);
        g_rt = NULL;
        return -1;
    }
    install_weft(g_ctx);
    g_cmds = JS_NewArray(g_ctx);
    g_on_output = JS_UNDEFINED;
    g_on_pick = JS_UNDEFINED;
    g_on_exit = JS_UNDEFINED;
    g_on_context_changed = JS_UNDEFINED;
    g_on_subject_changed = JS_UNDEFINED;
    JSValue global = JS_GetGlobalObject(g_ctx);
    JSValue weft = JS_GetPropertyStr(g_ctx, global, "weft");
    JS_SetPropertyStr(g_ctx, weft, "command", JS_NewCFunction(g_ctx, js_command, "command", 2));
    JS_SetPropertyStr(g_ctx, weft, "procSpawn", JS_NewCFunction(g_ctx, js_proc_spawn, "procSpawn", 1));
    JS_SetPropertyStr(g_ctx, weft, "procSend", JS_NewCFunction(g_ctx, js_proc_send, "procSend", 2));
    JS_SetPropertyStr(g_ctx, weft, "procRead", JS_NewCFunction(g_ctx, js_proc_read, "procRead", 1));
    JS_SetPropertyStr(g_ctx, weft, "procClose", JS_NewCFunction(g_ctx, js_proc_close, "procClose", 1));
    JS_SetPropertyStr(g_ctx, weft, "bufferAppend", JS_NewCFunction(g_ctx, js_buffer_append, "bufferAppend", 2));
    JS_SetPropertyStr(g_ctx, weft, "bufferFold", JS_NewCFunction(g_ctx, js_buffer_fold, "bufferFold", 3));
    JS_SetPropertyStr(g_ctx, weft, "bufferLen", JS_NewCFunction(g_ctx, js_buffer_len, "bufferLen", 1));
    JS_SetPropertyStr(g_ctx, weft, "transcriptEntry", JS_NewCFunction(g_ctx, js_transcript_entry, "transcriptEntry", 3));
    JS_SetPropertyStr(g_ctx, weft, "transcriptAppend", JS_NewCFunction(g_ctx, js_transcript_append, "transcriptAppend", 2));
    JS_SetPropertyStr(g_ctx, weft, "config", JS_NewCFunction(g_ctx, js_config, "config", 1));
    JS_SetPropertyStr(g_ctx, weft, "breakpoints", JS_NewCFunction(g_ctx, js_breakpoints, "breakpoints", 1));
    JS_SetPropertyStr(g_ctx, weft, "fileRead", JS_NewCFunction(g_ctx, js_file_read, "fileRead", 1));
    JS_SetPropertyStr(g_ctx, weft, "fileWrite", JS_NewCFunction(g_ctx, js_file_write, "fileWrite", 2));
    // The read surface, the same bodies a wasm plugin's wl_* doors run.
    JS_SetPropertyStr(g_ctx, weft, "cursor", JS_NewCFunction(g_ctx, js_cursor, "cursor", 0));
    JS_SetPropertyStr(g_ctx, weft, "byteLen", JS_NewCFunction(g_ctx, js_byte_len, "byteLen", 0));
    JS_SetPropertyStr(g_ctx, weft, "slice", JS_NewCFunction(g_ctx, js_slice, "slice", 2));
    JS_SetPropertyStr(g_ctx, weft, "lineAt", JS_NewCFunction(g_ctx, js_line_at, "lineAt", 1));
    JS_SetPropertyStr(g_ctx, weft, "selection", JS_NewCFunction(g_ctx, js_selection, "selection", 0));
    JS_SetPropertyStr(g_ctx, weft, "path", JS_NewCFunction(g_ctx, js_path, "path", 0));
    JS_SetPropertyStr(g_ctx, weft, "jump", JS_NewCFunction(g_ctx, js_jump, "jump", 1));
    JS_SetPropertyStr(g_ctx, weft, "pointer", JS_NewCFunction(g_ctx, js_pointer, "pointer", 0));
    JS_SetPropertyStr(g_ctx, weft, "clipboardSet", JS_NewCFunction(g_ctx, js_clipboard_set, "clipboardSet", 1));
    JS_SetPropertyStr(g_ctx, weft, "clipboardGet", JS_NewCFunction(g_ctx, js_clipboard_get, "clipboardGet", 0));
    JS_SetPropertyStr(g_ctx, weft, "contextSet", JS_NewCFunction(g_ctx, js_context_set, "contextSet", 3));
    JS_SetPropertyStr(g_ctx, weft, "contextGet", JS_NewCFunction(g_ctx, js_context_get, "contextGet", 1));
    JS_SetPropertyStr(g_ctx, weft, "onContextChanged", JS_NewCFunction(g_ctx, js_on_context_changed, "onContextChanged", 1));
    JS_SetPropertyStr(g_ctx, weft, "places", JS_NewCFunction(g_ctx, js_places, "places", 0));
    JS_SetPropertyStr(g_ctx, weft, "subjectWatch", JS_NewCFunction(g_ctx, js_subject_watch, "subjectWatch", 2));
    JS_SetPropertyStr(g_ctx, weft, "onSubjectChanged", JS_NewCFunction(g_ctx, js_on_subject_changed, "onSubjectChanged", 1));
    JS_SetPropertyStr(g_ctx, weft, "toolBacking", JS_NewCFunction(g_ctx, js_tool_backing, "toolBacking", 1));
    JS_SetPropertyStr(g_ctx, weft, "designation", JS_NewCFunction(g_ctx, js_designation, "designation", 0));
    JS_SetPropertyStr(g_ctx, weft, "designate", JS_NewCFunction(g_ctx, js_designate, "designate", 1));
    JS_SetPropertyStr(g_ctx, weft, "designationOpener", JS_NewCFunction(g_ctx, js_designation_opener, "designationOpener", 2));
    JS_SetPropertyStr(g_ctx, weft, "jumpPush", JS_NewCFunction(g_ctx, js_jump_push, "jumpPush", 0));
    JS_SetPropertyStr(g_ctx, weft, "macroRecording", JS_NewCFunction(g_ctx, js_macro_recording, "macroRecording", 0));
    JS_SetPropertyStr(g_ctx, weft, "lineText", JS_NewCFunction(g_ctx, js_line_text, "lineText", 0));
    JS_SetPropertyStr(g_ctx, weft, "activeBuffer", JS_NewCFunction(g_ctx, js_active_buffer, "activeBuffer", 0));
    JS_SetPropertyStr(g_ctx, weft, "pick", JS_NewCFunction(g_ctx, js_pick, "pick", 3));
    JS_SetPropertyStr(g_ctx, weft, "onPick", JS_NewCFunction(g_ctx, js_on_pick, "onPick", 1));
    JS_SetPropertyStr(g_ctx, weft, "commandMeta", JS_NewCFunction(g_ctx, js_command_meta, "commandMeta", 1));
    JS_SetPropertyStr(g_ctx, weft, "keysFor", JS_NewCFunction(g_ctx, js_keys_for, "keysFor", 1));
    JS_SetPropertyStr(g_ctx, weft, "status", JS_NewCFunction(g_ctx, js_status, "status", 1));
    JS_SetPropertyStr(g_ctx, weft, "onOutput", JS_NewCFunction(g_ctx, js_on_output, "onOutput", 1));
    JS_SetPropertyStr(g_ctx, weft, "onExit", JS_NewCFunction(g_ctx, js_on_exit, "onExit", 1));
    JS_FreeValue(g_ctx, weft);
    JS_FreeValue(g_ctx, global);
    JSValue val = JS_Eval(g_ctx, src, (size_t)len, "<plugin>", JS_EVAL_TYPE_GLOBAL);
    int rc = 0;
    if (JS_IsException(val)) {
        log_exception(g_ctx);
        rc = -1;
    }
    JS_FreeValue(g_ctx, val);
    return rc;
}

// weft_on_output(handle): dispatch to the registered proc-stream output handler.
__attribute__((export_name("weft_on_output")))
void weft_on_output(int handle) {
    if (!g_ctx || !JS_IsFunction(g_ctx, g_on_output)) return;
    JSValue arg = JS_NewInt32(g_ctx, handle);
    JSValue r = JS_Call(g_ctx, g_on_output, JS_UNDEFINED, 1, &arg);
    if (JS_IsException(r)) log_exception(g_ctx);
    JS_FreeValue(g_ctx, r);
    JS_FreeValue(g_ctx, arg);
}

// weft_on_context_changed(): the primary context moved; hand the handler the
// keys (read from the host during this call). At the frame boundary, never
// inside a dispatch — a handler needing a head goes through weft.run.
__attribute__((export_name("weft_on_context_changed")))
void weft_on_context_changed(void) {
    if (!g_ctx || !JS_IsFunction(g_ctx, g_on_context_changed)) return;
    JSValue keys = read_host_lines(g_ctx, host_context_changed);
    if (JS_IsException(keys)) {
        log_exception(g_ctx);
        return;
    }
    JSValue r = JS_Call(g_ctx, g_on_context_changed, JS_UNDEFINED, 1, &keys);
    if (JS_IsException(r)) log_exception(g_ctx);
    JS_FreeValue(g_ctx, r);
    JS_FreeValue(g_ctx, keys);
}

// weft_on_subject_changed(): a watched subject reads differently. The host
// binds the call to the subject's entry, so its designation — handed to the
// handler — and every read during the call are the subject's.
__attribute__((export_name("weft_on_subject_changed")))
void weft_on_subject_changed(void) {
    if (!g_ctx || !JS_IsFunction(g_ctx, g_on_subject_changed)) return;
    JSValue subject = read_host_string(g_ctx, host_designation);
    if (JS_IsException(subject)) {
        log_exception(g_ctx);
        return;
    }
    JSValue r = JS_Call(g_ctx, g_on_subject_changed, JS_UNDEFINED, 1, &subject);
    if (JS_IsException(r)) log_exception(g_ctx);
    JS_FreeValue(g_ctx, r);
    JS_FreeValue(g_ctx, subject);
}

// weft_on_exit(handle): dispatch the child's exit, once, after its last bytes.
// BACKGROUND, exactly like weft_on_output: no dispatching head, so a handler
// that needs one goes through a nested weft.run.
__attribute__((export_name("weft_on_exit")))
void weft_on_exit(int handle) {
    if (!g_ctx || !JS_IsFunction(g_ctx, g_on_exit)) return;
    JSValue arg = JS_NewInt32(g_ctx, handle);
    JSValue r = JS_Call(g_ctx, g_on_exit, JS_UNDEFINED, 1, &arg);
    if (JS_IsException(r)) log_exception(g_ctx);
    JS_FreeValue(g_ctx, r);
    JS_FreeValue(g_ctx, arg);
}

// weft_on_pick(kind, index, text, text_len, query, query_len, match_start,
//              match_span, token, token_len): dispatch one structured pick
// outcome. kind is 0=candidate, 1=input, 2=cancelled. `token` is the
// continuation identity `weft.pick` was opened with, delivered on EVERY kind
// (a cancellation must resolve its own request too).
__attribute__((export_name("weft_on_pick")))
void weft_on_pick(int kind, int index, const char *text, int text_len,
                  const char *query, int query_len, int match_start,
                  int match_span, const char *token, int token_len) {
    if (!g_ctx || !JS_IsFunction(g_ctx, g_on_pick)) return;
    JSValue arg = JS_NewObject(g_ctx);
    const char *text_ptr = text ? text : "";
    const char *query_ptr = query ? query : "";
    if (kind == 0) {
        JS_SetPropertyStr(g_ctx, arg, "kind", JS_NewString(g_ctx, "candidate"));
        JS_SetPropertyStr(g_ctx, arg, "index", JS_NewInt32(g_ctx, index));
        JS_SetPropertyStr(g_ctx, arg, "text", JS_NewStringLen(g_ctx, text_ptr, (size_t)(text_len < 0 ? 0 : text_len)));
        JS_SetPropertyStr(g_ctx, arg, "query", JS_NewStringLen(g_ctx, query_ptr, (size_t)(query_len < 0 ? 0 : query_len)));
        JSValue match = JS_NewObject(g_ctx);
        JS_SetPropertyStr(g_ctx, match, "start", JS_NewInt32(g_ctx, match_start));
        JS_SetPropertyStr(g_ctx, match, "span", JS_NewInt32(g_ctx, match_span));
        JS_SetPropertyStr(g_ctx, arg, "match", match);
    } else if (kind == 1) {
        JS_SetPropertyStr(g_ctx, arg, "kind", JS_NewString(g_ctx, "input"));
        JS_SetPropertyStr(g_ctx, arg, "text", JS_NewStringLen(g_ctx, text_ptr, (size_t)(text_len < 0 ? 0 : text_len)));
    } else {
        JS_SetPropertyStr(g_ctx, arg, "kind", JS_NewString(g_ctx, "cancelled"));
    }
    JS_SetPropertyStr(g_ctx, arg, "token",
                      JS_NewStringLen(g_ctx, token ? token : "",
                                      (size_t)(token_len < 0 ? 0 : token_len)));
    JSValue r = JS_Call(g_ctx, g_on_pick, JS_UNDEFINED, 1, &arg);
    if (JS_IsException(r)) log_exception(g_ctx);
    JS_FreeValue(g_ctx, r);
    JS_FreeValue(g_ctx, arg);
}

// weft_on_command(id): dispatch to the JS handler registered under `id`.
__attribute__((export_name("weft_on_command")))
void weft_on_command(int id) {
    if (!g_ctx) return;
    JSValue fn = JS_GetPropertyUint32(g_ctx, g_cmds, (uint32_t)id);
    if (JS_IsFunction(g_ctx, fn)) {
        JSValue r = JS_Call(g_ctx, fn, JS_UNDEFINED, 0, NULL);
        if (JS_IsException(r)) log_exception(g_ctx);
        JS_FreeValue(g_ctx, r);
    }
    JS_FreeValue(g_ctx, fn);
}

// Sealed eval (north-star-plan §2.3/§4 C11, M3 review R2): the CONFIG plane
// (weft_eval, below) is a declarative, hash-approved evaluation — its
// output (a manifest.zig `Manifest`) must be a pure function of the source
// text, so a config script cannot make Date.now()/Math.random() (QuickJS's
// OWN built-ins — not a `weft.*` import, so the qjs_contract's "no clock/
// env-shaped import" audit can't see them) leak nondeterminism into a
// `weft.set(...)` value and falsify the hash/reconcile-no-op guarantee.
// Evaluated ONCE, immediately after `install_weft`, before any user source:
// overrides `Date`/`Date.now`/`Math.random` with fixed-seed deterministic
// replacements. Plain ES5 (no arrow/rest/spread) — this runs before we've
// established the engine handles anything fancier, and it must never be the
// thing that breaks. `weft_plugin_init` (the LIVE plugin plane, below) does
// NOT get this — a resident plugin is not a one-shot declarative eval; its
// `weft.*` calls mutate the editor immediately at any point in its lifetime,
// so sealing would just make an agent/proc-timing plugin's Date.now() lie.
static const char *SEAL_PRELUDE =
    "(function(){\n"
    "  var _OrigDate = Date;\n"
    "  function SealedDate() {\n"
    "    if (arguments.length === 0) return new _OrigDate(0);\n"
    "    var args = Array.prototype.slice.call(arguments);\n"
    "    var Bound = Function.prototype.bind.apply(_OrigDate, [null].concat(args));\n"
    "    return new Bound();\n"
    "  }\n"
    "  SealedDate.prototype = _OrigDate.prototype;\n"
    "  Object.defineProperty(_OrigDate.prototype, 'constructor',\n"
    "    { value: SealedDate });\n"
    "  SealedDate.now = function() { return 0; };\n"
    "  SealedDate.parse = _OrigDate.parse;\n"
    "  SealedDate.UTC = _OrigDate.UTC;\n"
    "  globalThis.Date = SealedDate;\n"
    "  var _seed = 123456789;\n"
    "  globalThis.Math.random = function() {\n"
    "    _seed ^= _seed << 13;\n"
    "    _seed |= 0;\n"
    "    _seed ^= _seed >>> 17;\n"
    "    _seed ^= _seed << 5;\n"
    "    _seed |= 0;\n"
    "    return ((_seed >>> 0) % 1000000) / 1000000;\n"
    "  };\n"
    "})();\n";

// Install the deterministic-seal prelude into `ctx`. Returns 0 on success,
// -1 on a JS exception (the seal itself failing is a bug in SEAL_PRELUDE,
// not a config author's mistake — logged the same way, but distinctly, so
// it's diagnosable).
static int install_seal(JSContext *ctx) {
    JSValue val = JS_Eval(ctx, SEAL_PRELUDE, strlen(SEAL_PRELUDE), "<seal>", JS_EVAL_TYPE_GLOBAL);
    int rc = 0;
    if (JS_IsException(val)) {
        log_exception(ctx);
        rc = -1;
    }
    JS_FreeValue(ctx, val);
    return rc;
}

// Evaluate `len` bytes of JS at `src` (owned by the host, in linear memory)
// as the config program. Returns 0 on success, -1 on a JS exception. Each
// call is a fresh runtime — the config plane holds no state between evals.
__attribute__((export_name("weft_eval")))
int weft_eval(const char *src, int len) {
    JSRuntime *rt = JS_NewRuntime();
    if (!rt) return -1;
    JSContext *ctx = JS_NewContext(rt);
    if (!ctx) {
        JS_FreeRuntime(rt);
        return -1;
    }
    install_weft(ctx);
    if (install_seal(ctx) != 0) {
        JS_FreeContext(ctx);
        JS_FreeRuntime(rt);
        return -1;
    }
    JSValue val = JS_Eval(ctx, src, (size_t)len, "<config>", JS_EVAL_TYPE_GLOBAL);
    int rc = 0;
    if (JS_IsException(val)) {
        log_exception(ctx);
        rc = -1;
    }
    JS_FreeValue(ctx, val);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    return rc;
}
