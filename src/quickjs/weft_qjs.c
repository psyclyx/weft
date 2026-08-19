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
__attribute__((import_module("weft"), import_name("qjs_bind_key")))
extern void host_bind_key(const char *mode, int mode_len,
                          const char *key, int key_len,
                          const char *cmd, int cmd_len);
__attribute__((import_module("weft"), import_name("qjs_run")))
extern void host_run(const char *cmd, int cmd_len);
__attribute__((import_module("weft"), import_name("qjs_echo")))
extern void host_echo(const char *msg, int msg_len);
__attribute__((import_module("weft"), import_name("qjs_log")))
extern void host_log(const char *msg, int msg_len);
__attribute__((import_module("weft"), import_name("qjs_plugin")))
extern void host_plugin(const char *name, int name_len);
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
__attribute__((import_module("weft"), import_name("qjs_action")))
extern void host_action(const char *name, int name_len);
__attribute__((import_module("weft"), import_name("qjs_provide")))
extern void host_provide(const char *action, int action_len,
                         const char *mode, int mode_len,
                         const char *lang, int lang_len,
                         const char *cmd, int cmd_len, int prio);

// ── JS → host trampolines. Each pulls its string args out of the JS values
// and forwards to the host import. ──

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
    if (argc < 1) return JS_ThrowTypeError(ctx, "run(cmd)");
    size_t cl;
    const char *c = JS_ToCStringLen(ctx, &cl, argv[0]);
    if (c) host_run(c, (int)cl);
    JS_FreeCString(ctx, c);
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

// Install the `weft` global: the config surface config.js calls.
static void install_weft(JSContext *ctx) {
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue weft = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, weft, "bind", JS_NewCFunction(ctx, js_bind_key, "bind", 3));
    JS_SetPropertyStr(ctx, weft, "run", JS_NewCFunction(ctx, js_run, "run", 1));
    JS_SetPropertyStr(ctx, weft, "echo", JS_NewCFunction(ctx, js_echo, "echo", 1));
    JS_SetPropertyStr(ctx, weft, "log", JS_NewCFunction(ctx, js_log, "log", 1));
    JS_SetPropertyStr(ctx, weft, "plugin", JS_NewCFunction(ctx, js_plugin, "plugin", 1));
    JS_SetPropertyStr(ctx, weft, "set", JS_NewCFunction(ctx, js_set, "set", 3));
    JS_SetPropertyStr(ctx, weft, "menu", JS_NewCFunction(ctx, js_menu, "menu", 1));
    JS_SetPropertyStr(ctx, weft, "action", JS_NewCFunction(ctx, js_action, "action", 1));
    JS_SetPropertyStr(ctx, weft, "provide", JS_NewCFunction(ctx, js_provide, "provide", 3));
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

// weft.onOutput(fn): register the handler the host fires (with a stream handle)
// when that stream has new bytes to read.
static JSValue js_on_output(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv) {
    if (argc < 1 || !JS_IsFunction(ctx, argv[0])) return JS_UNDEFINED;
    JS_FreeValue(ctx, g_on_output);
    g_on_output = JS_DupValue(ctx, argv[0]);
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
    JSValue global = JS_GetGlobalObject(g_ctx);
    JSValue weft = JS_GetPropertyStr(g_ctx, global, "weft");
    JS_SetPropertyStr(g_ctx, weft, "command", JS_NewCFunction(g_ctx, js_command, "command", 2));
    JS_SetPropertyStr(g_ctx, weft, "procSpawn", JS_NewCFunction(g_ctx, js_proc_spawn, "procSpawn", 2));
    JS_SetPropertyStr(g_ctx, weft, "procSend", JS_NewCFunction(g_ctx, js_proc_send, "procSend", 2));
    JS_SetPropertyStr(g_ctx, weft, "procRead", JS_NewCFunction(g_ctx, js_proc_read, "procRead", 1));
    JS_SetPropertyStr(g_ctx, weft, "procClose", JS_NewCFunction(g_ctx, js_proc_close, "procClose", 1));
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
    JSValue val = JS_Eval(ctx, src, (size_t)len, "<config>", JS_EVAL_TYPE_GLOBAL);
    int rc = 0;
    if (JS_IsException(val)) {
        JSValue exc = JS_GetException(ctx);
        const char *msg = JS_ToCString(ctx, exc);
        if (msg) {
            host_log(msg, (int)strlen(msg));
            JS_FreeCString(ctx, msg);
        }
        JS_FreeValue(ctx, exc);
        rc = -1;
    }
    JS_FreeValue(ctx, val);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    return rc;
}
