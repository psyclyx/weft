//! Plugins — each one a Lua 5.4 VM of its own (crash/state isolation by
//! construction) *and* a Document peer of its own (its edits merge like
//! a remote collaborator's; "buffer changed under me" is not
//! expressible). Fennel is compiled in: plugin and config sources are
//! Fennel, evaluated through the embedded fennel.lua.
//!
//! The VM sees one global, `scion`:
//!   scion.snapshot()            → sync own replica to head, return text
//!   scion.insert(off, text)     → edit own replica (offsets valid at
//!   scion.delete(start, end)      the last snapshot)
//!   scion.commit()              → merge own ops into the document
//!   scion.run(name, ...)        → invoke any command (the same ABI
//!                                 keys and built-ins use)
//!   scion.command(name, summary, fn) → register a command
//!   scion.bind(mode, key, command)   → keymap binding
//!   scion.mode([name])          → get/set keymap mode
//!   scion.fallback(mode, parent) → keymap mode inheritance
//!   scion.textinput(mode, cmd|nil) → unbound-text command for a mode
//!   scion.pick(prompt, items, fn[, opts]) → fuzzy-select, callback on
//!                                 accept; items are strings or
//!                                 {text, doc} (or nil with a source).
//!                                 opts: {free_text, source="files"|
//!                                 "dir", root, min_query, debounce_ms}
//!   scion.read(prompt, opts, fn) → read a line; opts {candidates,
//!                                 source, root, allow_new=true} — accept
//!                                 the typed text (C-j) or a candidate
//!   scion.cursor()              → the user cursor's current offset
//!   scion.log(msg)              → editor log
//!   scion.buffers()             → open-buffer introspection (tables)
//!   scion.commands()            → command registry ({name, summary})
//!   scion.layer_publish(name, spans) → anchored sections/faces
//!   scion.section_at(name, off) → innermost span at an offset
//!
//! The user's config IS a plugin (named "config") — it gets no special
//! powers, which is the point. The BUNDLED plugin (src/bundled.fnl,
//! named "std") builds the buffers picker / status / help on these
//! same mechanisms — UI policy stays scriptable and rebindable.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const command = @import("command.zig");
const Document = @import("Document.zig");
const layers_mod = @import("layers.zig");
const Value = command.Value;

pub const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});

const fennel_src = @embedFile("fennel.lua");

pub const Error = error{ OutOfMemory, Script };

const LuaCommand = struct {
    plugin: *Plugin,
    ref: c_int,
    name: []u8,
    summary: []u8,
};

pub const Plugin = struct {
    gpa: Allocator,
    name: []u8,
    L: *c.lua_State,
    /// One peer per document, registered lazily: a plugin edits
    /// whichever buffer is active (or the tool buffer it created) and
    /// each document sees it as its own collaborator. Entries are
    /// validated on use (a closed buffer's address may be reused).
    peers: std.AutoHashMapUnmanaged(*Document, Document.PeerId) = .empty,
    ctx: *command.Context,
    cmds: std.ArrayList(*LuaCommand) = .empty,
    provs: std.ArrayList(*LuaProvider) = .empty,
    /// Owns string results returned across the trampoline until the
    /// next scripted-command invocation.
    result_buf: ?[]u8 = null,

    /// `ctx` must be stable for the plugin's lifetime.
    pub fn create(gpa: Allocator, ctx: *command.Context, name: []const u8) (Error || Document.AddPeerError)!*Plugin {
        const self = try gpa.create(Plugin);
        errdefer gpa.destroy(self);
        const L = c.luaL_newstate() orelse return error.OutOfMemory;
        errdefer c.lua_close(L);
        self.* = .{
            .gpa = gpa,
            .name = try gpa.dupe(u8, name),
            .L = L,
            .ctx = ctx,
        };
        errdefer gpa.free(self.name);
        c.luaL_openlibs(L);

        // Compile fennel in.
        if (c.luaL_loadbufferx(L, fennel_src, fennel_src.len, "fennel.lua", "t") != c.LUA_OK) {
            logLuaError(L, "loading fennel");
            return error.Script;
        }
        if (c.lua_pcallk(L, 0, 1, 0, 0, null) != c.LUA_OK) {
            logLuaError(L, "initializing fennel");
            return error.Script;
        }
        c.lua_setfield(L, c.LUA_REGISTRYINDEX, "scion_fennel");

        // The scion table: every entry closes over this plugin.
        c.lua_createtable(L, 0, 12);
        registerFn(L, self, "snapshot", lSnapshot);
        registerFn(L, self, "insert", lInsert);
        registerFn(L, self, "delete", lDelete);
        registerFn(L, self, "commit", lCommit);
        registerFn(L, self, "run", lRun);
        registerFn(L, self, "command", lCommand);
        registerFn(L, self, "bind", lBind);
        registerFn(L, self, "mode", lMode);
        registerFn(L, self, "fallback", lFallback);
        registerFn(L, self, "textinput", lTextinput);
        registerFn(L, self, "pick", lPick);
        registerFn(L, self, "read", lRead);
        registerFn(L, self, "provide", lProvide);
        registerFn(L, self, "cursor", lCursor);
        registerFn(L, self, "log", lLog);
        registerFn(L, self, "layer_publish", lLayerPublish);
        registerFn(L, self, "section_at", lSectionAt);
        registerFn(L, self, "buffers", lBuffers);
        registerFn(L, self, "commands", lCommands);
        c.lua_setglobal(L, "scion");
        return self;
    }

    /// The plugin's peer on `doc`, registered on first use and
    /// re-validated against buffer-close address reuse.
    fn peerFor(self: *Plugin, doc: *Document) (Error || Document.AddPeerError)!Document.PeerId {
        const gop = try self.peers.getOrPut(self.gpa, doc);
        if (gop.found_existing) {
            const idx = @intFromEnum(gop.value_ptr.*) - 1;
            if (idx < doc.peers.items.len) {
                if (doc.peers.items[idx]) |p| {
                    if (std.mem.eql(u8, p.name, self.name)) return gop.value_ptr.*;
                }
            }
            // Stale entry (the old document died); fall through.
        }
        gop.value_ptr.* = doc.addPeer(self.gpa, self.name) catch |e| switch (e) {
            error.DuplicatePeer => blk: {
                // The doc already has our peer; recover its id.
                for (doc.peers.items, 0..) |slot, i| {
                    if (slot) |p| {
                        if (std.mem.eql(u8, p.name, self.name)) {
                            break :blk @enumFromInt(i + 1);
                        }
                    }
                }
                unreachable;
            },
            else => |err| return err,
        };
        return gop.value_ptr.*;
    }

    pub fn destroy(self: *Plugin) void {
        const gpa = self.gpa;
        // Unbind the commands this VM provided (their trampoline data
        // dies with us).
        for (self.cmds.items) |lc| {
            if (self.ctx.commands.find(lc.name)) |n| self.ctx.commands.unbind(n);
            gpa.free(lc.name);
            gpa.free(lc.summary);
            gpa.destroy(lc);
        }
        self.cmds.deinit(gpa);
        // Capability providers this VM registered die with it.
        var prefix_buf: [128]u8 = undefined;
        if (std.fmt.bufPrint(&prefix_buf, "plugin.{s}/", .{self.name})) |prefix| {
            self.ctx.caps.unregisterByIdPrefix(prefix);
        } else |_| {}
        for (self.provs.items) |lp| {
            gpa.free(lp.id);
            gpa.destroy(lp);
        }
        self.provs.deinit(gpa);
        if (self.result_buf) |b| gpa.free(b);
        c.lua_close(self.L);
        // Deregister our peers from documents that still live (closed
        // buffers took theirs down with them).
        var bit = self.ctx.buffers.iterator();
        while (bit.next()) |buf| {
            if (self.peers.get(&buf.editor.doc)) |peer| {
                const idx = @intFromEnum(peer) - 1;
                if (idx < buf.editor.doc.peers.items.len) {
                    if (buf.editor.doc.peers.items[idx]) |p| {
                        if (std.mem.eql(u8, p.name, self.name)) {
                            buf.editor.doc.removePeer(gpa, peer);
                        }
                    }
                }
            }
        }
        self.peers.deinit(gpa);
        gpa.free(self.name);
        gpa.destroy(self);
    }

    /// Evaluate Fennel source; returns the result rendered to a string
    /// (caller owns), or error.Script (details on the log).
    pub fn eval(self: *Plugin, gpa: Allocator, source: []const u8, chunk_name: [:0]const u8) Error![]u8 {
        const L = self.L;
        const base = c.lua_gettop(L);
        defer c.lua_settop(L, base);

        _ = c.lua_getfield(L, c.LUA_REGISTRYINDEX, "scion_fennel");
        _ = c.lua_getfield(L, -1, "eval");
        _ = c.lua_pushlstring(L, source.ptr, source.len);
        // opts: {filename = chunk_name}
        c.lua_createtable(L, 0, 1);
        _ = c.lua_pushstring(L, chunk_name);
        c.lua_setfield(L, -2, "filename");
        if (c.lua_pcallk(L, 2, 1, 0, 0, null) != c.LUA_OK) {
            logLuaError(L, chunk_name);
            return error.Script;
        }
        var len: usize = 0;
        const s = c.luaL_tolstring(L, -1, &len);
        defer c.lua_pop(L, 1);
        return gpa.dupe(u8, s[0..len]);
    }
};

fn registerFn(L: *c.lua_State, self: *Plugin, name: [:0]const u8, f: c.lua_CFunction) void {
    c.lua_pushlightuserdata(L, self);
    c.lua_pushcclosure(L, f, 1);
    c.lua_setfield(L, -2, name);
}

fn pluginOf(L: ?*c.lua_State) *Plugin {
    const p = c.lua_touserdata(L, c.lua_upvalueindex(1));
    return @ptrCast(@alignCast(p.?));
}

fn logLuaError(L: ?*c.lua_State, what: []const u8) void {
    var len: usize = 0;
    const msg = c.lua_tolstring(L, -1, &len);
    std.log.err("lua ({s}): {s}", .{ what, if (msg != null) msg[0..len] else "?" });
    c.lua_pop(L, 1);
}

/// Raise a lua error from a Zig error (never returns).
fn raise(L: ?*c.lua_State, err: anyerror) c_int {
    _ = c.lua_pushstring(L, @errorName(err));
    return c.lua_error(L);
}

// ── scion.* implementations ─────────────────────────────────────────

fn lSnapshot(L: ?*c.lua_State) callconv(.c) c_int {
    const self = pluginOf(L);
    const doc = self.ctx.document();
    const peer = self.peerFor(doc) catch |e| return raise(L, e);
    var snap = doc.peerSnapshot(self.ctx.gpa, peer) catch |e| return raise(L, e);
    defer snap.deinit(self.ctx.gpa);
    const bytes = snap.rope.toOwnedSlice(self.ctx.gpa) catch |e| return raise(L, e);
    defer self.ctx.gpa.free(bytes);
    _ = c.lua_pushlstring(L, bytes.ptr, bytes.len);
    return 1;
}

fn lInsert(L: ?*c.lua_State) callconv(.c) c_int {
    const self = pluginOf(L);
    const off = c.luaL_checkinteger(L, 1);
    var len: usize = 0;
    const s = c.luaL_checklstring(L, 2, &len);
    if (off < 0) return raise(L, error.NegativeOffset);
    const doc = self.ctx.document();
    const peer = self.peerFor(doc) catch |e| return raise(L, e);
    doc.peerInsert(self.ctx.gpa, peer, @intCast(off), s[0..len]) catch |e| return raise(L, e);
    return 0;
}

fn lDelete(L: ?*c.lua_State) callconv(.c) c_int {
    const self = pluginOf(L);
    const start = c.luaL_checkinteger(L, 1);
    const end = c.luaL_checkinteger(L, 2);
    if (start < 0 or end < start) return raise(L, error.BadRange);
    const doc = self.ctx.document();
    const peer = self.peerFor(doc) catch |e| return raise(L, e);
    doc.peerDelete(self.ctx.gpa, peer, .{
        .start = @intCast(start),
        .end = @intCast(end),
    }) catch |e| return raise(L, e);
    return 0;
}

fn lCommit(L: ?*c.lua_State) callconv(.c) c_int {
    const self = pluginOf(L);
    const doc = self.ctx.document();
    const peer = self.peerFor(doc) catch |e| return raise(L, e);
    const changed = doc.peerCommit(self.ctx.gpa, peer) catch |e| return raise(L, e);
    c.lua_pushboolean(L, @intFromBool(changed));
    return 1;
}

/// scion.buffers() → array of {id, name, path?, dirty, read_only,
/// active, backing, unfetched} — the open-buffer set, for pickers and
/// status lines built in config/plugins (mechanism here, policy there).
fn lBuffers(L: ?*c.lua_State) callconv(.c) c_int {
    const self = pluginOf(L);
    const bufs = self.ctx.buffers;
    c.lua_createtable(L, @intCast(bufs.count()), 0);
    var it = bufs.iterator();
    var i: c.lua_Integer = 1;
    while (it.next()) |b| : (i += 1) {
        c.lua_createtable(L, 0, 8);
        c.lua_pushinteger(L, @intCast(b.id));
        c.lua_setfield(L, -2, "id");
        _ = c.lua_pushlstring(L, b.name.ptr, b.name.len);
        c.lua_setfield(L, -2, "name");
        if (b.editor.backingPath()) |p| {
            _ = c.lua_pushlstring(L, p.ptr, p.len);
            c.lua_setfield(L, -2, "path");
        }
        c.lua_pushboolean(L, @intFromBool(b.editor.isDirty(self.ctx.gpa) catch true));
        c.lua_setfield(L, -2, "dirty");
        c.lua_pushboolean(L, @intFromBool(b.read_only));
        c.lua_setfield(L, -2, "read_only");
        c.lua_pushboolean(L, @intFromBool(b == bufs.active()));
        c.lua_setfield(L, -2, "active");
        const backing: []const u8 = switch (b.editor.backing) {
            .none => "scratch",
            .file => "file",
            .shell => "shell",
            .tool => "tool",
        };
        _ = c.lua_pushlstring(L, backing.ptr, backing.len);
        c.lua_setfield(L, -2, "backing");
        var unfetched: usize = 0;
        for (b.editor.doc.unrealizedBase()) |h| unfetched += h.bytes;
        c.lua_pushinteger(L, @intCast(unfetched));
        c.lua_setfield(L, -2, "unfetched");
        c.lua_rawseti(L, -2, i);
    }
    return 1;
}

/// scion.commands() → array of {name, summary, args={{name, type}...}}
/// — registry introspection for palettes/help built in plugins. The arg
/// schema drives argument-aware invocation (inline parse / per-arg
/// prompts); `type` is one of "nil"|"boolean"|"integer"|"number"|
/// "string".
fn lCommands(L: ?*c.lua_State) callconv(.c) c_int {
    const self = pluginOf(L);
    const cmds = self.ctx.commands;
    c.lua_createtable(L, @intCast(cmds.count()), 0);
    var out_i: c.lua_Integer = 1;
    for (0..cmds.count()) |i| {
        const n: command.Commands.Name = @enumFromInt(i);
        const cmd = cmds.lookup(n) orelse continue;
        c.lua_createtable(L, 0, 3);
        const name = cmds.nameOf(n);
        _ = c.lua_pushlstring(L, name.ptr, name.len);
        c.lua_setfield(L, -2, "name");
        _ = c.lua_pushlstring(L, cmd.summary.ptr, cmd.summary.len);
        c.lua_setfield(L, -2, "summary");
        c.lua_createtable(L, @intCast(cmd.args.len), 0);
        for (cmd.args, 0..) |a, ai| {
            c.lua_createtable(L, 0, 2);
            _ = c.lua_pushlstring(L, a.name.ptr, a.name.len);
            c.lua_setfield(L, -2, "name");
            const tn = @tagName(a.type);
            _ = c.lua_pushlstring(L, tn.ptr, tn.len);
            c.lua_setfield(L, -2, "type");
            c.lua_rawseti(L, -2, @intCast(ai + 1));
        }
        c.lua_setfield(L, -2, "args");
        c.lua_rawseti(L, -2, out_i);
        out_i += 1;
    }
    return 1;
}

/// scion.layer_publish(name, spans) — publish anchored sections/faces
/// on the active buffer as a local layer owned by this plugin. `spans`
/// is an array of {start, end, kind, message?} tables (byte offsets at
/// the current head; kind integer; message optional string). Tool
/// buffers use this for their section structure (rev 3).
fn lLayerPublish(L: ?*c.lua_State) callconv(.c) c_int {
    const self = pluginOf(L);
    const gpa = self.ctx.gpa;
    var nlen: usize = 0;
    const name_c = c.luaL_checklstring(L, 1, &nlen);
    c.luaL_checktype(L, 2, c.LUA_TTABLE);
    const doc = self.ctx.document();

    var spans: std.ArrayList(layers_mod.SpanIn) = .empty;
    defer spans.deinit(gpa);
    const n = c.lua_rawlen(L, 2);
    const max = doc.text().byteLen();
    var i: c.lua_Integer = 1;
    while (i <= n) : (i += 1) {
        _ = c.lua_rawgeti(L, 2, i); // spans[i]
        if (c.lua_type(L, -1) != c.LUA_TTABLE) {
            c.lua_pop(L, 1);
            return raise(L, error.BadSpan);
        }
        _ = c.lua_rawgeti(L, -1, 1);
        _ = c.lua_rawgeti(L, -2, 2);
        _ = c.lua_rawgeti(L, -3, 3);
        _ = c.lua_rawgeti(L, -4, 4);
        const start = c.lua_tointegerx(L, -4, null);
        const stop = c.lua_tointegerx(L, -3, null);
        const kind = c.lua_tointegerx(L, -2, null);
        var mlen: usize = 0;
        const msg = if (c.lua_type(L, -1) == c.LUA_TSTRING) c.lua_tolstring(L, -1, &mlen) else null;
        const bad = start < 0 or stop < start or @as(usize, @intCast(stop)) > max;
        if (!bad) {
            spans.append(gpa, .{
                .start = @intCast(start),
                .end = @intCast(stop),
                .kind = @intCast(@max(0, kind)),
                .message = if (msg) |m| m[0..mlen] else "",
            }) catch |e| {
                c.lua_pop(L, 5);
                return raise(L, e);
            };
        }
        c.lua_pop(L, 5); // fields + spans[i]
        if (bad) return raise(L, error.BadSpan);
    }
    const layer = self.ctx.caps.layers.claim(gpa, doc, name_c[0..nlen], .local, self.name) catch |e| return raise(L, e);
    layer.publishSpans(gpa, spans.items) catch |e| return raise(L, e);
    return 0;
}

/// scion.section_at(name, offset) → start, end, kind, message | nil —
/// the innermost span of the named layer containing `offset` (cursor →
/// section resolution for tool buffers).
fn lSectionAt(L: ?*c.lua_State) callconv(.c) c_int {
    const self = pluginOf(L);
    var nlen: usize = 0;
    const name_c = c.luaL_checklstring(L, 1, &nlen);
    const off_i = c.luaL_checkinteger(L, 2);
    if (off_i < 0) return raise(L, error.NegativeOffset);
    const off: usize = @intCast(off_i);
    const doc = self.ctx.document();
    const layer = self.ctx.caps.layers.find(doc, name_c[0..nlen]) orelse {
        c.lua_pushnil(L);
        return 1;
    };
    var best: ?layers_mod.Layer.ResolvedSpan = null;
    for (0..layer.spanCount()) |i| {
        const s = layer.resolvedSpan(i);
        if (off >= s.start and off <= s.end) {
            if (best == null or (s.end - s.start) < (best.?.end - best.?.start)) best = s;
        }
    }
    const s = best orelse {
        c.lua_pushnil(L);
        return 1;
    };
    c.lua_pushinteger(L, @intCast(s.start));
    c.lua_pushinteger(L, @intCast(s.end));
    c.lua_pushinteger(L, @intCast(s.kind));
    _ = c.lua_pushlstring(L, s.message.ptr, s.message.len);
    return 4;
}

fn lRun(L: ?*c.lua_State) callconv(.c) c_int {
    const self = pluginOf(L);
    var name_len: usize = 0;
    const name = c.luaL_checklstring(L, 1, &name_len);
    const nargs: usize = @intCast(@max(0, c.lua_gettop(L) - 1));
    var vals: [8]Value = undefined;
    if (nargs > vals.len) return raise(L, error.TooManyArguments);
    for (0..nargs) |i| vals[i] = luaToValue(L, @intCast(i + 2));
    const result = command.run(self.ctx.commands, self.ctx, name[0..name_len], vals[0..nargs]) catch |e| return raise(L, e);
    pushValue(L, result);
    return 1;
}

fn lCommand(L: ?*c.lua_State) callconv(.c) c_int {
    const self = pluginOf(L);
    var name_len: usize = 0;
    const name = c.luaL_checklstring(L, 1, &name_len);
    var sum_len: usize = 0;
    const summary = c.luaL_checklstring(L, 2, &sum_len);
    c.luaL_checktype(L, 3, c.LUA_TFUNCTION);
    const gpa = self.gpa;

    c.lua_pushvalue(L, 3);
    const ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);
    const lc = gpa.create(LuaCommand) catch |e| return raise(L, e);
    lc.* = .{
        .plugin = self,
        .ref = ref,
        .name = gpa.dupe(u8, name[0..name_len]) catch |e| return raise(L, e),
        .summary = gpa.dupe(u8, summary[0..sum_len]) catch |e| return raise(L, e),
    };
    self.cmds.append(gpa, lc) catch |e| return raise(L, e);
    _ = self.ctx.commands.bind(gpa, lc.name, .{
        .name = lc.name,
        .summary = lc.summary,
        .args = &.{}, // scripted commands are dynamically typed
        .handler = luaTrampoline,
        .data = lc,
    }) catch |e| return raise(L, e);
    return 0;
}

fn lBind(L: ?*c.lua_State) callconv(.c) c_int {
    const self = pluginOf(L);
    var ml: usize = 0;
    const mode = c.luaL_checklstring(L, 1, &ml);
    var kl: usize = 0;
    const key = c.luaL_checklstring(L, 2, &kl);
    var cl: usize = 0;
    const cmd = c.luaL_checklstring(L, 3, &cl);
    self.ctx.keymap.bind(self.ctx.gpa, mode[0..ml], key[0..kl], cmd[0..cl]) catch |e| return raise(L, e);
    return 0;
}

fn lMode(L: ?*c.lua_State) callconv(.c) c_int {
    const self = pluginOf(L);
    if (c.lua_gettop(L) == 0) {
        const m = self.ctx.keymap.currentMode();
        _ = c.lua_pushlstring(L, m.ptr, m.len);
        return 1;
    }
    var ml: usize = 0;
    const mode = c.luaL_checklstring(L, 1, &ml);
    self.ctx.keymap.setMode(self.ctx.gpa, mode[0..ml]) catch |e| return raise(L, e);
    return 0;
}

fn lFallback(L: ?*c.lua_State) callconv(.c) c_int {
    const self = pluginOf(L);
    var ml: usize = 0;
    const mode = c.luaL_checklstring(L, 1, &ml);
    var pl: usize = 0;
    const parent = c.luaL_checklstring(L, 2, &pl);
    self.ctx.keymap.setFallback(self.ctx.gpa, mode[0..ml], parent[0..pl]) catch |e| return raise(L, e);
    return 0;
}

fn lTextinput(L: ?*c.lua_State) callconv(.c) c_int {
    const self = pluginOf(L);
    var ml: usize = 0;
    const mode = c.luaL_checklstring(L, 1, &ml);
    var cmd: ?[]const u8 = null;
    if (c.lua_type(L, 2) == c.LUA_TSTRING) {
        var cl: usize = 0;
        const s = c.lua_tolstring(L, 2, &cl);
        cmd = s[0..cl];
    }
    self.ctx.keymap.setTextCommand(self.ctx.gpa, mode[0..ml], cmd) catch |e| return raise(L, e);
    return 0;
}

const pick_mod = @import("pick.zig");
const fs_source = @import("fs_source.zig");

const LuaPick = struct {
    plugin: *Plugin,
    ref: c_int,
};

fn optBool(L: ?*c.lua_State, idx: c_int, key: [:0]const u8) bool {
    if (idx == 0) return false;
    _ = c.lua_getfield(L, idx, key);
    defer c.lua_pop(L, 1);
    return c.lua_toboolean(L, -1) != 0;
}

fn optInt(L: ?*c.lua_State, idx: c_int, key: [:0]const u8, default: i64) i64 {
    if (idx == 0) return default;
    _ = c.lua_getfield(L, idx, key);
    defer c.lua_pop(L, 1);
    if (c.lua_isinteger(L, -1) != 0) return c.lua_tointegerx(L, -1, null);
    if (c.lua_type(L, -1) == c.LUA_TNUMBER) return @intFromFloat(c.lua_tonumberx(L, -1, null));
    return default;
}

/// Build a native candidate source from an opts table's `source` field
/// ("files" | "dir", with `root`, `min_query`, `debounce_ms`). Producers
/// walk on the shared thread pool and stream in; the pick's fuzzy filter
/// narrows. Returns null when no source is requested.
fn buildSource(self: *Plugin, L: ?*c.lua_State, opts_idx: c_int) !?pick_mod.Source {
    if (opts_idx == 0 or c.lua_type(L, opts_idx) != c.LUA_TTABLE) return null;
    _ = c.lua_getfield(L, opts_idx, "source");
    if (c.lua_type(L, -1) != c.LUA_TSTRING) {
        c.lua_pop(L, 1);
        return null;
    }
    var kl: usize = 0;
    const ks = c.lua_tolstring(L, -1, &kl);
    const kind = ks[0..kl];
    _ = c.lua_getfield(L, opts_idx, "root");
    var rl: usize = 0;
    const root: []const u8 = if (c.lua_type(L, -1) == c.LUA_TSTRING) blk: {
        const rs = c.lua_tolstring(L, -1, &rl);
        break :blk rs[0..rl];
    } else ".";
    const gpa = self.ctx.gpa;
    const pool = self.ctx.buffers.pool;
    var src: ?pick_mod.Source = null;
    if (std.mem.eql(u8, kind, "files")) {
        const f = fs_source.LocalFinder.create(gpa, pool, root) catch |e| {
            c.lua_pop(L, 2);
            return e;
        };
        src = f.source();
    } else if (std.mem.eql(u8, kind, "dir")) {
        const d = fs_source.LocalDir.create(gpa, pool, root) catch |e| {
            c.lua_pop(L, 2);
            return e;
        };
        src = d.source();
    }
    c.lua_pop(L, 2); // root, source
    if (src) |*s| {
        s.min_query = @intCast(@max(0, optInt(L, opts_idx, "min_query", 0)));
        s.debounce_ns = @intCast(@max(0, optInt(L, opts_idx, "debounce_ms", 0)) * std.time.ns_per_ms);
    }
    return src;
}

/// The shared open path for `scion.pick` / `scion.read`. `items_idx` /
/// `opts_idx` are absolute stack indices (0 = absent); `free_text` is
/// resolved by the caller (pick reads opts.free_text; read maps
/// allow_new). Refs the accept fn, builds the source last (no fallible
/// step between it and `openWith`), then opens.
fn openPick(
    self: *Plugin,
    L: ?*c.lua_State,
    prompt_idx: c_int,
    items_idx: c_int,
    accept_idx: c_int,
    opts_idx: c_int,
    free_text: bool,
) c_int {
    const gpa = self.gpa;
    var pl: usize = 0;
    const prompt = c.luaL_checklstring(L, prompt_idx, &pl);
    c.luaL_checktype(L, accept_idx, c.LUA_TFUNCTION);

    // Collect entries: each element is a string, or a table whose [1]
    // is the text and [2] (or .doc) the docstring.
    var items: std.ArrayList(pick_mod.Entry) = .empty;
    defer {
        for (items.items) |e| {
            gpa.free(@constCast(e.text));
            if (e.doc.len > 0) gpa.free(@constCast(e.doc));
        }
        items.deinit(gpa);
    }
    if (items_idx != 0 and c.lua_type(L, items_idx) == c.LUA_TTABLE) {
        const n = c.lua_rawlen(L, items_idx);
        for (1..n + 1) |i| {
            _ = c.lua_rawgeti(L, items_idx, @intCast(i));
            var text: []u8 = undefined;
            var doc: []const u8 = "";
            if (c.lua_type(L, -1) == c.LUA_TTABLE) {
                _ = c.lua_rawgeti(L, -1, 1);
                var tl: usize = 0;
                const ts = c.luaL_tolstring(L, -1, &tl);
                text = gpa.dupe(u8, ts[0..tl]) catch |e| return raise(L, e);
                c.lua_pop(L, 2);
                _ = c.lua_rawgeti(L, -1, 2);
                if (c.lua_type(L, -1) == c.LUA_TNIL) {
                    c.lua_pop(L, 1);
                    _ = c.lua_getfield(L, -1, "doc");
                }
                if (c.lua_type(L, -1) != c.LUA_TNIL) {
                    var dl: usize = 0;
                    const ds = c.luaL_tolstring(L, -1, &dl);
                    doc = gpa.dupe(u8, ds[0..dl]) catch |e| {
                        gpa.free(text);
                        return raise(L, e);
                    };
                    c.lua_pop(L, 1); // tolstring's copy
                }
                c.lua_pop(L, 1); // the doc value / nil
            } else {
                var sl: usize = 0;
                const s = c.luaL_tolstring(L, -1, &sl);
                text = gpa.dupe(u8, s[0..sl]) catch |e| return raise(L, e);
                c.lua_pop(L, 1); // tolstring's copy
            }
            c.lua_pop(L, 1); // the raw element
            items.append(gpa, .{ .text = text, .doc = doc }) catch |e| {
                gpa.free(text);
                if (doc.len > 0) gpa.free(@constCast(doc));
                return raise(L, e);
            };
        }
    }

    c.lua_pushvalue(L, accept_idx);
    const ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);
    const lp = gpa.create(LuaPick) catch |e| {
        c.luaL_unref(L, c.LUA_REGISTRYINDEX, ref);
        return raise(L, e);
    };
    lp.* = .{ .plugin = self, .ref = ref };
    // Build the source immediately before openWith: on openWith failure
    // it closes the source itself, so we only unwind the ref + LuaPick.
    const src = buildSource(self, L, opts_idx) catch |e| {
        c.luaL_unref(L, c.LUA_REGISTRYINDEX, ref);
        gpa.destroy(lp);
        return raise(L, e);
    };
    self.ctx.pick.openWith(self.ctx, prompt[0..pl], items.items, .{
        .handler = luaPickAccept,
        .cleanup = luaPickCleanup,
        .data = lp,
    }, .{ .allow_free_text = free_text, .source = src }) catch |e| {
        c.luaL_unref(L, c.LUA_REGISTRYINDEX, ref);
        gpa.destroy(lp);
        return raise(L, e);
    };
    return 0;
}

fn lPick(L: ?*c.lua_State) callconv(.c) c_int {
    const self = pluginOf(L);
    const opts_idx: c_int = if (c.lua_gettop(L) >= 4 and c.lua_type(L, 4) == c.LUA_TTABLE) 4 else 0;
    const free_text = optBool(L, opts_idx, "free_text");
    return openPick(self, L, 1, 2, 3, opts_idx, free_text);
}

/// scion.read(prompt, opts, fn) — a line reader. `opts.candidates` seeds
/// the list; `opts.source`/`root` attach a native producer;
/// `opts.allow_new` (default true) permits accepting the typed text.
fn lRead(L: ?*c.lua_State) callconv(.c) c_int {
    const self = pluginOf(L);
    const opts_idx: c_int = if (c.lua_type(L, 2) == c.LUA_TTABLE) 2 else 0;
    // candidates → items: push the nested table and use its stack index.
    var items_idx: c_int = 0;
    if (opts_idx != 0) {
        _ = c.lua_getfield(L, opts_idx, "candidates");
        if (c.lua_type(L, -1) == c.LUA_TTABLE) {
            items_idx = c.lua_gettop(L);
        } else c.lua_pop(L, 1);
    }
    // allow_new defaults to true (a reader accepts free text).
    const allow_new = if (opts_idx == 0) true else blk: {
        _ = c.lua_getfield(L, opts_idx, "allow_new");
        defer c.lua_pop(L, 1);
        if (c.lua_type(L, -1) == c.LUA_TBOOLEAN) break :blk c.lua_toboolean(L, -1) != 0;
        break :blk true;
    };
    return openPick(self, L, 1, items_idx, 3, opts_idx, allow_new);
}

fn luaPickAccept(ctx: *command.Context, data: ?*anyopaque, choice: []const u8) anyerror!void {
    _ = ctx;
    const lp: *LuaPick = @ptrCast(@alignCast(data.?));
    const L = lp.plugin.L;
    const base = c.lua_gettop(L);
    defer c.lua_settop(L, base);
    _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, lp.ref);
    _ = c.lua_pushlstring(L, choice.ptr, choice.len);
    if (c.lua_pcallk(L, 1, 0, 0, 0, null) != c.LUA_OK) {
        logLuaError(L, "pick callback");
        return error.Script;
    }
}

fn luaPickCleanup(data: ?*anyopaque, gpa: Allocator) void {
    const lp: *LuaPick = @ptrCast(@alignCast(data.?));
    c.luaL_unref(lp.plugin.L, c.LUA_REGISTRYINDEX, lp.ref);
    gpa.destroy(lp);
}

const capability = @import("capability.zig");

const LuaProvider = struct {
    plugin: *Plugin,
    ref: c_int,
    id: []u8,
};

/// scion.provide(capability, fn) — register a scripted capability
/// provider (instant class, all documents). v1 scope: edit/completion;
/// the handler receives the word prefix and returns a list of strings
/// (or {text=..., label=...} tables).
fn lProvide(L: ?*c.lua_State) callconv(.c) c_int {
    const self = pluginOf(L);
    var nl: usize = 0;
    const cap = c.luaL_checklstring(L, 1, &nl);
    c.luaL_checktype(L, 2, c.LUA_TFUNCTION);
    if (!std.mem.eql(u8, cap[0..nl], "edit/completion")) {
        return raise(L, error.UnsupportedCapability);
    }
    const gpa = self.gpa;
    c.lua_pushvalue(L, 2);
    const ref = c.luaL_ref(L, c.LUA_REGISTRYINDEX);
    const lp = gpa.create(LuaProvider) catch |e| return raise(L, e);
    lp.* = .{
        .plugin = self,
        .ref = ref,
        .id = std.fmt.allocPrint(gpa, "plugin.{s}/{s}", .{ self.name, cap[0..nl] }) catch |e| return raise(L, e),
    };
    self.provs.append(gpa, lp) catch |e| return raise(L, e);
    self.ctx.caps.register(.{
        .capability = cap[0..nl],
        .id = lp.id,
        .latency = .instant,
        .data = lp,
        .handler = luaProviderQuery,
    }) catch |e| return raise(L, e);
    return 0;
}

fn luaProviderQuery(data: ?*anyopaque, caps: *capability.Caps, req: *const capability.Request) anyerror!void {
    const lp: *LuaProvider = @ptrCast(@alignCast(data.?));
    if (req.kind != .completion) {
        caps.decline(req.session);
        return;
    }
    const L = lp.plugin.L;
    const base = c.lua_gettop(L);
    defer c.lua_settop(L, base);
    _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, lp.ref);
    _ = c.lua_pushlstring(L, req.text.ptr, req.text.len);
    if (c.lua_pcallk(L, 1, 1, 0, 0, null) != c.LUA_OK) {
        logLuaError(L, "capability provider");
        caps.decline(req.session);
        return error.Script;
    }
    if (c.lua_type(L, -1) != c.LUA_TTABLE) {
        caps.decline(req.session);
        return;
    }
    const gpa = lp.plugin.gpa;
    var items: std.ArrayList(capability.CompletionItem) = .empty;
    defer items.deinit(gpa);
    const n = c.lua_rawlen(L, -1);
    for (1..n + 1) |i| {
        _ = c.lua_rawgeti(L, -1, @intCast(i));
        var text: ?[]const u8 = null;
        if (c.lua_type(L, -1) == c.LUA_TSTRING) {
            var sl: usize = 0;
            const s = c.lua_tolstring(L, -1, &sl);
            text = s[0..sl];
        } else if (c.lua_type(L, -1) == c.LUA_TTABLE) {
            _ = c.lua_getfield(L, -1, "text");
            if (c.lua_type(L, -1) == c.LUA_TSTRING) {
                var sl: usize = 0;
                const s = c.lua_tolstring(L, -1, &sl);
                text = s[0..sl];
            }
            c.lua_pop(L, 1);
        }
        if (text) |t_| {
            try items.append(gpa, .{
                .text = @constCast(t_), // borrowed; push() deep-copies
                .rank = @intCast(i),
            });
        }
        c.lua_pop(L, 1);
    }
    try caps.push(req.session, .{ .id = lp.id, .latency = .instant }, .{ .completion = items.items });
}

fn lCursor(L: ?*c.lua_State) callconv(.c) c_int {
    const self = pluginOf(L);
    c.lua_pushinteger(L, @intCast(self.ctx.editor().cursorOffset()));
    return 1;
}

fn lLog(L: ?*c.lua_State) callconv(.c) c_int {
    const self = pluginOf(L);
    var len: usize = 0;
    const s = c.luaL_checklstring(L, 1, &len);
    std.log.info("plugin {s}: {s}", .{ self.name, s[0..len] });
    return 0;
}

// ── Value bridge ────────────────────────────────────────────────────

fn luaToValue(L: ?*c.lua_State, idx: c_int) Value {
    switch (c.lua_type(L, idx)) {
        c.LUA_TNIL, c.LUA_TNONE => return .nil,
        c.LUA_TBOOLEAN => return .{ .boolean = c.lua_toboolean(L, idx) != 0 },
        c.LUA_TNUMBER => {
            if (c.lua_isinteger(L, idx) != 0) {
                return .{ .integer = c.lua_tointegerx(L, idx, null) };
            }
            return .{ .number = c.lua_tonumberx(L, idx, null) };
        },
        c.LUA_TSTRING => {
            var len: usize = 0;
            const s = c.lua_tolstring(L, idx, &len);
            return .{ .string = s[0..len] };
        },
        else => return .nil, // tables/functions don't cross the ABI
    }
}

fn pushValue(L: ?*c.lua_State, v: Value) void {
    switch (v) {
        .nil => c.lua_pushnil(L),
        .boolean => |b| c.lua_pushboolean(L, @intFromBool(b)),
        .integer => |i| c.lua_pushinteger(L, i),
        .number => |n| c.lua_pushnumber(L, n),
        .string => |s| _ = c.lua_pushlstring(L, s.ptr, s.len),
    }
}

/// A command implemented in a plugin VM: push the function, marshal the
/// args, pcall, marshal the result. String results live until this
/// plugin's next scripted invocation.
fn luaTrampoline(ctx: *command.Context, data: ?*anyopaque, args: []const Value) anyerror!Value {
    _ = ctx;
    const lc: *LuaCommand = @ptrCast(@alignCast(data.?));
    const self = lc.plugin;
    const L = self.L;
    const base = c.lua_gettop(L);
    defer c.lua_settop(L, base);

    _ = c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, lc.ref);
    for (args) |a| pushValue(L, a);
    if (c.lua_pcallk(L, @intCast(args.len), 1, 0, 0, null) != c.LUA_OK) {
        logLuaError(L, lc.name);
        return error.Script;
    }
    var result = luaToValue(L, -1);
    if (result == .string) {
        const owned = try self.gpa.dupe(u8, result.string);
        if (self.result_buf) |b| self.gpa.free(b);
        self.result_buf = owned;
        result = .{ .string = owned };
    }
    return result;
}

/// The `eval` command: Fennel source in, printed result out, executed
/// in this plugin's VM (the config VM, conventionally). Register it
/// with `commands.bind("eval", p.evalCommand())`.
pub fn evalCommand(self: *Plugin) command.Command {
    return .{
        .name = "eval",
        .summary = "Evaluate Fennel source in the config VM.",
        .args = &.{.{ .name = "code", .type = .string }},
        .handler = evalHandler,
        .data = self,
    };
}

fn evalHandler(ctx: *command.Context, data: ?*anyopaque, args: []const Value) anyerror!Value {
    _ = ctx;
    const self: *Plugin = @ptrCast(@alignCast(data.?));
    if (args.len != 1 or args[0] != .string) return error.TypeMismatch;
    const out = try self.eval(self.gpa, args[0].string, "eval");
    if (self.result_buf) |b| self.gpa.free(b);
    self.result_buf = out;
    return .{ .string = out };
}

test {
    std.testing.refAllDecls(@This());
}
