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
