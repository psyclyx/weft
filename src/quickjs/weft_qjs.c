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

// Install the `weft` global: the config surface config.js calls.
static void install_weft(JSContext *ctx) {
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue weft = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, weft, "bind", JS_NewCFunction(ctx, js_bind_key, "bind", 3));
    JS_SetPropertyStr(ctx, weft, "run", JS_NewCFunction(ctx, js_run, "run", 1));
    JS_SetPropertyStr(ctx, weft, "echo", JS_NewCFunction(ctx, js_echo, "echo", 1));
    JS_SetPropertyStr(ctx, weft, "log", JS_NewCFunction(ctx, js_log, "log", 1));
    JS_SetPropertyStr(ctx, global, "weft", weft);
    JS_FreeValue(ctx, global);
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
