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

__attribute__((import_module("weft"), import_name("qjs_bind_key")))
extern void host_bind_key(const char *mode, int mode_len,
                          const char *key, int key_len,
                          const char *cmd, int cmd_len);
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
// Plugin plane (persistent runtime): register a command, get a host-assigned id
// (the value the host passes back to weft_on_command). Config satisfies this
// import with a stub (it never registers commands).
__attribute__((import_module("weft"), import_name("qjs_register")))
extern int host_register(const char *name, int name_len);
// Plugin proc-stream membrane: a persistent duplex child whose stdout the guest
// reads (an ACP agent, an LSP-shaped tool). Config satisfies these with stubs.
__attribute__((import_module("weft"), import_name("qjs_proc_spawn")))
extern int host_proc_spawn(const char *cmd, int cmd_len, const char *cwd, int cwd_len);
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
// start a new role-tagged entry in this plugin's single-instance live
// TranscriptDoc (created on first call), re-filling `name`'s projected
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
__attribute__((import_module("weft"), import_name("qjs_file_write")))
extern void host_file_write(const char *path, int path_len, const char *content, int content_len, const char *agent, int agent_len);
// The text of the active buffer's current line (at the cursor) — a prompt line.
__attribute__((import_module("weft"), import_name("qjs_line_text")))
extern int host_line_text(char *out, int cap);
// Open a pick (prompt + newline-joined options); the structured acceptance
// comes back via weft_on_pick. An async approve/deny for a permission request.
__attribute__((import_module("weft"), import_name("qjs_pick")))
extern void host_pick(const char *prompt, int plen, const char *opts, int olen);
// Set the status-line chip (the "● agent · waiting" indicator). "" clears it.
__attribute__((import_module("weft"), import_name("qjs_status")))
extern void host_status(const char *text, int len);
__attribute__((import_module("weft"), import_name("qjs_action")))
extern void host_action(const char *name, int name_len);
__attribute__((import_module("weft"), import_name("qjs_semantic_action")))
extern void host_semantic_action(const char *name, int name_len);
__attribute__((import_module("weft"), import_name("qjs_provide")))
extern void host_provide(const char *action, int action_len,
                         const char *mode, int mode_len,
                         const char *lang, int lang_len,
                         const char *cmd, int cmd_len, int prio);
// weft.statusSegment(text, role, priority): stage a static ui/statusline-seg
// segment onto the manifest (north-star-plan §6 W3, task #19 item 3).
__attribute__((import_module("weft"), import_name("qjs_status_segment")))
extern void host_status_segment(const char *text, int text_len,
                                const char *role, int role_len, int priority);
// weft.grant(plugin, capability, opts): stage a GrantDecl onto the manifest
// (north-star-plan §6 W4 slice 4). `root` is opts.root ("" = unrestricted,
// Limit.none; non-empty narrows to Limit.fs_root) — the only limit kind a
// config script can author in v1 (see manifest.zig's ManifestGrantDecl doc
// for why doc-region limits stay runtime-only).
__attribute__((import_module("weft"), import_name("qjs_grant")))
extern void host_grant(const char *plugin, int plugin_len,
                       const char *capability, int capability_len,
                       const char *root, int root_len);

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

static JSValue js_bind_key(JSContext *ctx, JSValueConst this_val,
                           int argc, JSValueConst *argv) {
    if (argc < 3) return JS_ThrowTypeError(ctx, "bind(mode, key, cmd)");
    size_t ml, kl, cl;
    const char *m = JS_ToCStringLen(ctx, &ml, argv[0]);
    const char *k = JS_ToCStringLen(ctx, &kl, argv[1]);
    const char *c = JS_ToCStringLen(ctx, &cl, argv[2]);
    if (m && k && c) host_bind_key(m, (int)ml, k, (int)kl, c, (int)cl);
    JS_FreeCString(ctx, m);
    JS_FreeCString(ctx, k);
    JS_FreeCString(ctx, c);
    return JS_UNDEFINED;
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

// ── Config-data framing. weft.set(plugin, key, value) hands a plugin a small
// declarative table (its keymap, pairs, formatters, languages) that overrides
// the plugin's shipped defaults. `value` is a string (one record) or an array
// of strings (records). We frame it as uvarint(count) then count×(uvarint(len)
// ++ bytes) — the same LEB128 style kv/guest use — so the guest decoder can
// detect a short/truncated buffer rather than silently dropping tail records. ──

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

// weft.action(name) — declare an abstract intent a key can bind to; providers
// registered with weft.provide resolve it by context at fire time. Policy is
// `pick` (the config plane drives synchronous, command-shaped actions).
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

// weft.provide(action, when, cmd[, prio]) — register a provider for `action`.
// `when` is an object {mode?, lang?}; an absent field is "don't care". The
// highest-priority provider whose `when` holds in the current context wins when
// the action fires (ties break toward the more specific `when`).
static JSValue js_provide(JSContext *ctx, JSValueConst this_val,
                          int argc, JSValueConst *argv) {
    if (argc < 3) return JS_ThrowTypeError(ctx, "provide(action, when, cmd[, prio])");
    size_t al, cl;
    const char *a = JS_ToCStringLen(ctx, &al, argv[0]);
    const char *c = JS_ToCStringLen(ctx, &cl, argv[2]);
    const char *mode = NULL;
    size_t ml = 0;
    const char *lang = NULL;
    size_t ll = 0;
    JSValue jmode = JS_UNDEFINED, jlang = JS_UNDEFINED;
    if (JS_IsObject(argv[1])) {
        jmode = JS_GetPropertyStr(ctx, argv[1], "mode");
        if (!JS_IsUndefined(jmode) && !JS_IsNull(jmode)) mode = JS_ToCStringLen(ctx, &ml, jmode);
        jlang = JS_GetPropertyStr(ctx, argv[1], "lang");
        if (!JS_IsUndefined(jlang) && !JS_IsNull(jlang)) lang = JS_ToCStringLen(ctx, &ll, jlang);
    }
    int32_t prio = 0;
    if (argc >= 4) JS_ToInt32(ctx, &prio, argv[3]);
    if (a && c)
        host_provide(a, (int)al, mode ? mode : "", (int)ml,
                     lang ? lang : "", (int)ll, c, (int)cl, prio);
    JS_FreeCString(ctx, a);
    JS_FreeCString(ctx, c);
    if (mode) JS_FreeCString(ctx, mode);
    if (lang) JS_FreeCString(ctx, lang);
    JS_FreeValue(ctx, jmode);
    JS_FreeValue(ctx, jlang);
    return JS_UNDEFINED;
}

// weft.statusSegment(text, role[, priority]) — stage a static status-line
// segment (north-star-plan §6 W3, task #19). `role` names a
// core.surface.Role ("normal","muted","accent",…); unknown/empty falls back
// to "normal" host-side. `priority` defaults to 0 — the composition sort key
// within `ui/statusline-seg` (an ordered_union slot).
static JSValue js_status_segment(JSContext *ctx, JSValueConst this_val,
                                 int argc, JSValueConst *argv) {
    if (argc < 2) return JS_ThrowTypeError(ctx, "statusSegment(text, role[, priority])");
    size_t tl, rl;
    const char *txt = JS_ToCStringLen(ctx, &tl, argv[0]);
    const char *role = JS_ToCStringLen(ctx, &rl, argv[1]);
    int32_t prio = 0;
    if (argc >= 3) JS_ToInt32(ctx, &prio, argv[2]);
    if (txt && role) host_status_segment(txt, (int)tl, role, (int)rl, prio);
    JS_FreeCString(ctx, txt);
    JS_FreeCString(ctx, role);
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
    JS_SetPropertyStr(ctx, weft, "action", JS_NewCFunction(ctx, js_action, "action", 1));
    JS_SetPropertyStr(ctx, weft, "semanticAction", JS_NewCFunction(ctx, js_semantic_action, "semanticAction", 1));
    JS_SetPropertyStr(ctx, weft, "provide", JS_NewCFunction(ctx, js_provide, "provide", 3));
    JS_SetPropertyStr(ctx, weft, "statusSegment", JS_NewCFunction(ctx, js_status_segment, "statusSegment", 2));
    JS_SetPropertyStr(ctx, weft, "grant", JS_NewCFunction(ctx, js_grant, "grant", 2));
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

// weft.command(name, fn): register a command and remember its handler by the
// host-assigned id.
static JSValue js_command(JSContext *ctx, JSValueConst this_val,
                          int argc, JSValueConst *argv) {
    if (argc < 2 || !JS_IsFunction(ctx, argv[1]))
        return JS_ThrowTypeError(ctx, "command(name, fn)");
    size_t nl;
    const char *name = JS_ToCStringLen(ctx, &nl, argv[0]);
    if (!name) return JS_EXCEPTION;
    int id = host_register(name, (int)nl);
    JS_FreeCString(ctx, name);
    if (id >= 0) JS_SetPropertyUint32(ctx, g_cmds, (uint32_t)id, JS_DupValue(ctx, argv[1]));
    return JS_UNDEFINED;
}

// weft.procSpawn(cmd[, cwd]) -> handle (or -1): a persistent duplex child.
// Throws when the plugin holds no `proc` grant.
static JSValue js_proc_spawn(JSContext *ctx, JSValueConst this_val,
                             int argc, JSValueConst *argv) {
    if (argc < 1) return JS_ThrowTypeError(ctx, "procSpawn(cmd[, cwd])");
    size_t cl, wl = 0;
    const char *cmd = JS_ToCStringLen(ctx, &cl, argv[0]);
    const char *cwd = NULL;
    if (argc >= 2 && !JS_IsUndefined(argv[1]) && !JS_IsNull(argv[1]))
        cwd = JS_ToCStringLen(ctx, &wl, argv[1]);
    int h = -1;
    if (cmd) h = host_proc_spawn(cmd, (int)cl, cwd ? cwd : "", (int)wl);
    JS_FreeCString(ctx, cmd);
    if (cwd) JS_FreeCString(ctx, cwd);
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
    if (path && content) host_file_write(path, (int)pl, content, (int)cl, agent ? agent : "", (int)al);
    JS_FreeCString(ctx, path);
    JS_FreeCString(ctx, content);
    if (agent) JS_FreeCString(ctx, agent);
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

// weft.onOutput(fn): register the handler the host fires (with a stream handle)
// when that stream has new bytes to read.
static JSValue js_on_output(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv) {
    if (argc < 1 || !JS_IsFunction(ctx, argv[0])) return JS_UNDEFINED;
    JS_FreeValue(ctx, g_on_output);
    g_on_output = JS_DupValue(ctx, argv[0]);
    return JS_UNDEFINED;
}

// weft.pick(prompt, options): options is a newline-joined list. Empty rows are
// retained, so the candidate index is the original line ordinal. The handler
// receives one object describing candidate/input/cancelled acceptance.
static JSValue js_pick(JSContext *ctx, JSValueConst this_val,
                       int argc, JSValueConst *argv) {
    if (argc < 2) return JS_UNDEFINED;
    size_t pl, ol;
    const char *prompt = JS_ToCStringLen(ctx, &pl, argv[0]);
    const char *opts = JS_ToCStringLen(ctx, &ol, argv[1]);
    if (prompt && opts) host_pick(prompt, (int)pl, opts, (int)ol);
    JS_FreeCString(ctx, prompt);
    JS_FreeCString(ctx, opts);
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
    JSValue global = JS_GetGlobalObject(g_ctx);
    JSValue weft = JS_GetPropertyStr(g_ctx, global, "weft");
    JS_SetPropertyStr(g_ctx, weft, "command", JS_NewCFunction(g_ctx, js_command, "command", 2));
    JS_SetPropertyStr(g_ctx, weft, "procSpawn", JS_NewCFunction(g_ctx, js_proc_spawn, "procSpawn", 2));
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
    JS_SetPropertyStr(g_ctx, weft, "lineText", JS_NewCFunction(g_ctx, js_line_text, "lineText", 0));
    JS_SetPropertyStr(g_ctx, weft, "pick", JS_NewCFunction(g_ctx, js_pick, "pick", 2));
    JS_SetPropertyStr(g_ctx, weft, "onPick", JS_NewCFunction(g_ctx, js_on_pick, "onPick", 1));
    JS_SetPropertyStr(g_ctx, weft, "status", JS_NewCFunction(g_ctx, js_status, "status", 1));
    JS_SetPropertyStr(g_ctx, weft, "onOutput", JS_NewCFunction(g_ctx, js_on_output, "onOutput", 1));
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

// weft_on_pick(kind, index, text, text_len, query, query_len, match_start,
//              match_span): dispatch one structured pick outcome. kind is
// 0=candidate, 1=input, 2=cancelled.
__attribute__((export_name("weft_on_pick")))
void weft_on_pick(int kind, int index, const char *text, int text_len,
                  const char *query, int query_len, int match_start,
                  int match_span) {
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
