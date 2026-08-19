//! The pick's configuration/callback value types: the `Acceptor` a caller
//! hands `open`, the async candidate `Source`, the `open` `Options`, and the
//! `Entry` value type. Pure data + function pointers — the `Pick` state
//! machine in `state.zig` is built out of these.

const std = @import("std");
const Allocator = std.mem.Allocator;

const command = @import("../command.zig");
const match = @import("match.zig");

/// How the query filters candidates.
pub const Style = match.Style;

pub const Acceptor = struct {
    handler: *const fn (ctx: *command.Context, data: ?*anyopaque, choice: []const u8) anyerror!void,
    /// Called exactly once when the pick closes (accept or cancel).
    cleanup: ?*const fn (data: ?*anyopaque, gpa: Allocator) void = null,
    data: ?*anyopaque = null,
};

/// A candidate producer driven by the picker's per-frame `tick`. The
/// consult-async shape: `onQuery` (re)generates as the query changes
/// (epoch-tagged so stale generations self-discard), `poll` folds ready
/// candidates into the live pick each frame, `close` signals cancel and
/// drops the owner's reference when the pick closes. `close` must NEVER
/// block or join — the pick can close inside the input hot section, so
/// teardown hands off ownership (a refcount) rather than waiting.
///
/// A source that only walks once (file finder, dir listing) leaves
/// `onQuery` null and streams via `poll`; the general regenerate path
/// (grep) sets `onQuery`. The in-core fuzzy filter narrows either.
pub const Source = struct {
    onQuery: ?*const fn (data: ?*anyopaque, ctx: *command.Context, query: []const u8, epoch: u64) anyerror!void = null,
    poll: ?*const fn (data: ?*anyopaque, ctx: *command.Context) anyerror!bool = null,
    close: ?*const fn (data: ?*anyopaque, gpa: Allocator) void = null,
    data: ?*anyopaque = null,
    /// Below this query length `onQuery` is not fired (grep guard).
    min_query: usize = 0,
    /// Coalesce keystrokes: `onQuery` fires only once the query has been
    /// still this long.
    debounce_ns: u64 = 0,
};

pub const Options = struct {
    /// Accept the typed query itself (new filename, rename, freeform),
    /// not only an existing candidate. See `pick-accept-input`.
    allow_free_text: bool = false,
    source: ?Source = null,
    /// Completion style for this pick (default orderless).
    style: Style = .orderless,
};

/// One selectable item: the text is what matching and acceptance see;
/// the doc is display-only.
pub const Entry = struct {
    text: []const u8,
    doc: []const u8 = "",
};
