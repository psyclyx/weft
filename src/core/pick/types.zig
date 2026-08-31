//! The pick's configuration/callback value types: immutable acceptance
//! outcomes, the `Acceptor` a caller hands `open`, the async candidate
//! `Source`, the `open` `Options`, and the `Entry` value type. Pure data +
//! function pointers — the `Pick` state machine is built out of these.

const std = @import("std");
const Allocator = std.mem.Allocator;

const command = @import("../command.zig");
const match = @import("match.zig");

/// How the query filters candidates.
pub const Style = match.Style;

/// Match evidence captured at the same instant as candidate acceptance.
/// Offsets are bytes relative to the candidate's matchable `Entry.text`, not
/// to any document a source may have projected that text from.
pub const Match = struct {
    start: usize,
    span: usize,
};

/// One selected candidate. `index` is its stable add-order identity within
/// this pick, `text` is its accepted presentation value, and `query`/`match`
/// are the facts produced by the picker. Resolving those facts to a document,
/// buffer, remote offer, or synthetic target remains source policy.
pub const Candidate = struct {
    index: usize,
    text: []const u8,
    query: []const u8,
    match: Match,
};

/// The terminal result of one pick session. Cancellation is an event, not
/// merely cleanup, and free input is distinct from a candidate whose text
/// happens to equal the query. An acceptor receives exactly one of these
/// cases for every runtime termination of its interaction.
pub const Outcome = union(enum) {
    candidate: Candidate,
    input: []const u8,
    cancelled,

    pub fn text(self: Outcome) ?[]const u8 {
        return switch (self) {
            .candidate => |candidate| candidate.text,
            .input => |input| input,
            .cancelled => null,
        };
    }
};

pub const Acceptor = struct {
    /// Called exactly once when a live pick accepts or is cancelled. Every
    /// slice in `outcome` is callback-scoped and immutable. A picker owner
    /// must terminate before destroying its command context; `Pick.deinit`
    /// asserts that no live acceptor is being silently discarded.
    handler: *const fn (ctx: *command.Context, data: ?*anyopaque, outcome: Outcome) anyerror!void,
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
    /// What KIND of pick this is (`"file"`, `"buffer"`, `"command"`) —
    /// uninterpreted by everything in core; the only thing done with it is
    /// handing it to annotators (`pick/annotate.zig`).
    ///
    /// **Empty means no annotation, and that is the opt-in, not a default.**
    /// A pick that says nothing is never offered to an annotator, which is
    /// what makes git's destructive yes/no and an agent's permission prompt
    /// structurally undecorable rather than protected by a rule someone has
    /// to remember. It is deliberately NOT the prompt: a prompt is a label
    /// ("Discard 3 files?", "dir host:path"), and matching on prompt
    /// substrings is exactly how an annotator would end up decorating a
    /// confirmation dialog.
    category: []const u8 = "",
};

/// One selectable item: the text is what matching and acceptance see;
/// the doc is display-only.
pub const Entry = struct {
    text: []const u8,
    doc: []const u8 = "",
    /// An uninterpreted PUBLIC key for this row, for an annotator that cannot
    /// read the label. Empty = the text IS the key, which is the common case
    /// (a path, a command name).
    ///
    /// It exists for the buffer pick, where the label is `"3: foo.zig [ro] *"`
    /// and the identity is a `Buffers.Ref` living in the producer's own bound
    /// -pick state — something no annotator can resolve. The accept path still
    /// uses the `Ref`; this is a parallel, weaker handle that says only "here
    /// is a name you could look up", and core never parses it.
    key: []const u8 = "",
};
