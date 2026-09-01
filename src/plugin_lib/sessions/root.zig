//! sessions — one model per PLACE, in its own instanced buffer.
//!
//! A tool plugin that projects an external authority almost always projects a
//! per-directory one: a repository, a build tree, a test suite, a language
//! server's workspace. Two of them open at once are two models, two buffers,
//! and a rule for which one a keypress is about — and the rule is where the
//! bugs are, because the tempting answer ("the most recent") tracks the last
//! thing you touched anywhere.
//!
//! git wrote all of it: find-or-mint by root, mint the next free instance name
//! against both the live sessions and the open buffers, and route each command
//! by whether it means the place it is in, the buffer it is in, or the session
//! its caller already chose. None of that is about git.
//!
//! WHAT A PLUGIN KEEPS: its own `Value` per session — the model, the parse
//! state, whatever it holds. This library owns only IDENTITY (an id, a root, a
//! buffer name) and the routing, so a plugin's state struct does not have to
//! grow three fields it never reads.
//!
//! THE PLACE IS THE HOST'S ANSWER. `here()` asks where this dispatch runs
//! (`weft.placeRoot`) rather than climbing the filesystem for a marker. git
//! used to climb, which made it a SECOND detector of a fact the host already
//! detects, running on a grant that reached the whole filesystem to answer a
//! question about the user's own project. A place also makes the marker rule
//! right by construction: a project rooted at a `.jj` or `.hg` top stays its
//! own root instead of resolving to whatever enclosing checkout contains it.

const std = @import("std");
const weft = @import("weft");

/// Which session a command is about.
pub const Route = enum {
    /// The PLACE this dispatch runs in — find or mint. This is the door into a
    /// second project, and it must open one from a tool buffer too, so it asks
    /// the locus and never what is focused.
    place,
    /// The focused tool buffer's own session, so a key pressed in `*git:2*` can
    /// only ever act on project 2.
    focus,
    /// Whatever the caller already chose — the internal deferrals a background
    /// delivery schedules, which must never ask what is focused.
    carried,
};

pub const Config = struct {
    /// The instanced buffer's base name (`"git"` → `*git*`, `*git:2*`, …).
    base: []const u8,
    /// Said when a dispatch has no local directory to be a project in — a peer
    /// place, or a container that went away. Refusing by name beats minting a
    /// session that would fall through to wherever this process happens to be.
    no_place: []const u8,
    /// Said when a session cannot be minted for want of memory. The only
    /// refusal a mint has left, now that nothing here has a fixed ceiling.
    no_memory: []const u8,
    /// Longest buffer name held inline.
    name_capacity: usize = 64,
};

/// One plugin's sessions. Instantiate at container scope; the state below is
/// per-instantiation, and each guest is its own wasm module.
pub fn Registry(comptime Value: type, comptime cfg: Config) type {
    return struct {
        const Self = @This();

        pub const Session = struct {
            /// Stable for the session's life, and what a deferred answer names
            /// so it can be refused if the session closed while it was open.
            id: u32,
            /// The place this session is FOR. Owned, absolute.
            root: []u8,
            name_buf: [cfg.name_capacity]u8 = undefined,
            name_len: usize = 0,
            /// The plugin's own per-session state.
            value: Value = .{},

            pub fn name(self: *const Session) []const u8 {
                return self.name_buf[0..self.name_len];
            }
        };

        var list: std.ArrayList(*Session) = .empty;
        var next_id: u32 = 1;

        /// The session the CURRENT command is about. Every entry point routes
        /// before handing control to a handler, so a handler's read is always
        /// answered — the same dominated assertion `Buffers.active()` makes.
        pub var routed: ?*Session = null;

        pub fn all() []*Session {
            return list.items;
        }

        pub fn byId(id: u32) ?*Session {
            for (list.items) |s| {
                if (s.id == id) return s;
            }
            return null;
        }

        /// The session whose instanced buffer is focused, if any.
        pub fn focused() ?*Session {
            var buf: [cfg.name_capacity]u8 = undefined;
            const active = weft.activeBufferName(&buf) orelse return null;
            for (list.items) |s| {
                if (std.mem.eql(u8, s.name(), active)) return s;
            }
            return null;
        }

        /// The session already open for `root`, or null — the find half of
        /// `forRoot`, so a caller can PREFER "the session for where I am"
        /// without that preference itself opening a project.
        pub fn openFor(root: []const u8) ?*Session {
            if (root.len == 0) return null;
            for (list.items) |s| {
                if (std.mem.eql(u8, s.root, root)) return s;
            }
            return null;
        }

        /// Find-or-mint the session for `root`, taking the next free instance
        /// name.
        pub fn forRoot(root: []const u8) ?*Session {
            if (root.len == 0) {
                weft.echo(cfg.no_place);
                return null;
            }
            if (openFor(root)) |s| return s;
            var name_buf: [cfg.name_capacity]u8 = undefined;
            const minted = mintName(&name_buf) orelse return null;
            const alloc = weft.allocator;
            list.ensureUnusedCapacity(alloc, 1) catch return refuse();
            const owned = alloc.dupe(u8, root) catch return refuse();
            const s = alloc.create(Session) catch {
                alloc.free(owned);
                return refuse();
            };
            s.* = .{ .id = next_id, .root = owned };
            next_id += 1;
            s.name_len = @min(minted.len, s.name_buf.len);
            @memcpy(s.name_buf[0..s.name_len], minted[0..s.name_len]);
            list.appendAssumeCapacity(s);
            return s;
        }

        /// Which session this command is about. Routing, not preference: the
        /// fallthrough deliberately LOOKS UP rather than mints, because minting
        /// here would change when a second project silently opens.
        ///
        /// `.focus` used to fall straight through to "the most recent session",
        /// and "most recent" tracks the last thing you touched ANYWHERE — so a
        /// command run from a file in one project routinely acted on another.
        pub fn route(kind: Route) ?*Session {
            if (kind == .carried) return routed;
            if (kind == .place) return forRoot(here());
            if (focused()) |s| return s;
            if (openFor(here())) |s| return s;
            return if (list.items.len == 0) forRoot(here()) else routed;
        }

        fn refuse() ?*Session {
            weft.echo(cfg.no_memory);
            return null;
        }

        /// The lowest instance name neither a buffer nor a live session already
        /// answers to. Needs no ceiling: an ordinal is held only by a buffer or
        /// a live session, both finite, so one of the first
        /// `buffers + sessions + 1` is always free.
        fn mintName(out: []u8) ?[]const u8 {
            var n: u32 = 1;
            while (true) : (n += 1) {
                const candidate = weft.instanceName(cfg.base, n, out) orelse return null;
                if (weft.bufferNamed(candidate)) continue;
                if (taken(candidate)) continue;
                return candidate;
            }
        }

        fn taken(name: []const u8) bool {
            for (list.items) |s| {
                if (std.mem.eql(u8, s.name(), name)) return true;
            }
            return false;
        }

        // ── Where this dispatch runs ────────────────────────────────────────

        var here_buf: [1024]u8 = undefined;
        var path_buf: [1024]u8 = undefined;

        /// WHERE this dispatch runs, copied off the shim's shared read scratch.
        /// Empty when the place has no local directory at all, which every
        /// caller treats as a refusal rather than as "here".
        pub fn here() []const u8 {
            const root = weft.placeRoot();
            const n = @min(root.len, here_buf.len);
            @memcpy(here_buf[0..n], root[0..n]);
            return here_buf[0..n];
        }

        /// The focused buffer's file, absolute, or null for a tool buffer (or
        /// for a place with no local directory to name it against). `placePath`
        /// owns the join, because a path spelled relative to the launch
        /// directory and a place below it share components neither spelling
        /// admits to.
        pub fn pathHere() ?[]const u8 {
            const base = here();
            const abs = weft.placePath(base, weft.path() orelse return null, &path_buf);
            return if (abs.len == 0) null else abs;
        }
    };
}
