//! git — GATHER: run git, then re-read the world.
//!
//! What this file used to be, and why it is smaller now. Every read went out
//! through `procToBuffer`: a SHELL STRING whose stdout replaced a scratch
//! buffer, which the plugin then paged back out of the document with `slice`
//! into a fixed array. So a gather was one shell line concatenating four
//! commands with sentinel lines (`\x1e\x1e{U,S,R}`) printed between them,
//! because there was one output channel and the parser had to find the seams
//! again afterwards. And every mutation had to be FUSED into that same line
//! (`mutation && GATHER`) to avoid an async read/write race — four
//! near-identical wrappers, one per fusion shape.
//!
//! `weft.exec` returns each command's stdout, stderr, and exit status
//! separately, so:
//!
//!   - the four parts arrive as four results, and the parser is handed the
//!     boundaries the assembler recorded rather than sentinels it has to
//!     search for (`model.Part`, `Session.bounds`);
//!   - a mutation is its own command, and the re-gather is what its
//!     continuation does — no fusion, no `&&` vs `;` choice, and no
//!     `>/dev/null 2>&1` to suppress output that now simply goes to `stderr`
//!     where it belongs;
//!   - an exit status is a number. `git commit` used to `printf '\036\036C%d'`
//!     its own status into stdout for `takeEffectOutcome` to scan back out and
//!     splice away.
//!
//! And there is no shell, so there is no quoting: a path with an apostrophe,
//! a space, or a newline in it is one argument. The `'{s}'` wrapping every
//! interpolated path used to carry is gone, along with the class of bug it
//! could not actually prevent.
//!
//! WHERE it runs is `git -C <root>` (`rootedArgv`), which is what retired the
//! `cd .<root>. || exit 0` prologue every command carried. Same scoping, said
//! in git.s own vocabulary instead of a shell.s.

const std = @import("std");
const weft = @import("weft");
const model = @import("model.zig");
const render_mod = @import("render.zig");
const cur = model.cur;
const Target = model.Target;
const Part = model.Part;
const tool = model.tool;
const nodeAtCursor = render_mod.nodeAtCursor;

/// What a delivered part is about: which session asked, and which part it is.
/// Carried THROUGH the call by `execWith`, where the old design packed it into
/// a `u32` fill token and unpacked it in a demux switch.
const PartOf = struct { session: u32, part: Part };

/// What a finished mutation is about. `refresh` says whether landing it should
/// re-read the world (every mutation does; a plain read does not).
const AfterOf = struct { session: u32, note: bool = false };

/// Re-read the world into `session`'s model: four commands, fired together.
/// They may land in any order — each writes its own region and the last one
/// in triggers the parse.
pub fn gather() void {
    const s = cur();
    // The projection entry has to EXIST before anything is gathered into it:
    // `repaint` authors it. Created here, not by the fill door — which used to
    // do it as a side effect of being handed a buffer name to write into.
    if (!model.focusBuffer(s.name())) weft.runStr("buffer-create", s.name());
    weft.toolBacking(tool);
    s.gathering = true;
    s.raw_len = 0;
    s.pending_parts = model.part_count;
    for (0..model.part_count) |i| {
        const part: Part = @enumFromInt(i);
        s.bounds[i] = 0;
        _ = weft.execWith(PartOf, .{ .session = s.id, .part = part }, .{
            .argv = rootedArgv(model.argvFor(part)),
        }, partLanded);
    }
}

/// One part's output landed. Regions are assembled in `Part` order regardless
/// of arrival order, so the parser's view is deterministic even though four
/// subprocesses are not.
fn partLanded(r: weft.ExecDone, who: PartOf) void {
    const s = model.sessionById(who.session) orelse return;
    model.routed = s;
    // Stash this part's bytes; the assembly happens once every part is in.
    const idx = @intFromEnum(who.part);
    if (s.part_bytes[idx]) |stale| weft.allocator.free(stale);
    s.part_bytes[idx] = r.dupe(weft.allocator, .out) catch null;
    if (s.pending_parts > 0) s.pending_parts -= 1;
    if (s.pending_parts != 0) return;

    // Every part is in. Concatenate in Part order, recording each region's END
    // as we go — the boundary is known when it is created, so nothing has to
    // be recovered by searching the bytes.
    s.raw_len = 0;
    s.truncated_raw = false;
    for (0..model.part_count) |i| {
        const bytes = s.part_bytes[i] orelse &[_]u8{};
        const room = model.RAW_CAP - s.raw_len;
        const n = @min(bytes.len, room);
        if (n < bytes.len) s.truncated_raw = true;
        @memcpy(s.raw[s.raw_len..][0..n], bytes[0..n]);
        s.raw_len += n;
        s.bounds[i] = s.raw_len;
    }
    for (&s.part_bytes) |*held| {
        if (held.*) |bytes| weft.allocator.free(bytes);
        held.* = null;
    }
    s.gathering = false;
    s.snapshot +%= 1;
    if (model.on_gathered) |f| f();
}

/// Run a mutation, then re-read. The re-gather is the continuation, which is
/// what replaced fusing the two into one shell line to dodge a race: there is
/// no window between them for a read to observe a half-applied index, because
/// the read does not start until the write has returned.
pub fn after(argv: []const []const u8) void {
    afterInput(argv, null);
}

/// `after`, with bytes the command needs as a FILE — a synthesized patch, a
/// commit message, a rebase plan. The host writes them to a temp it names,
/// substitutes it for the bare `{}` argument, and removes it on every path.
/// git names no path it writes and cleans up nothing, which is why it still
/// holds no filesystem capability at all.
pub fn afterInput(argv: []const []const u8, input: ?[]const u8) void {
    markRestore();
    const s = cur();
    // Provisional from the moment the MUTATION is in flight, not from when its
    // re-gather starts. The fused shell line made these one command, so one
    // flag covered both; split apart, the window between them is exactly when
    // the visible rows describe an index that is already moving.
    s.gathering = true;
    _ = weft.execWith(AfterOf, .{ .session = s.id }, .{
        .argv = rootedArgv(argv),
        .input = input,
    }, mutationLanded);
    weft.setMode("git");
}

/// A mutation whose refusal the user should see — a commit, a rebase. Its
/// stderr is git's own words, and its status is git's own verdict; neither has
/// to be recovered from a marker in stdout.
pub fn afterNoted(argv: []const []const u8, input: ?[]const u8) void {
    markRestore();
    const s = cur();
    s.gathering = true;
    _ = weft.execWith(AfterOf, .{ .session = s.id, .note = true }, .{
        .argv = rootedArgv(argv),
        .input = input,
    }, mutationLanded);
}

fn mutationLanded(r: weft.ExecDone, who: AfterOf) void {
    const s = model.sessionById(who.session) orelse return;
    model.routed = s;
    if (who.note) {
        s.effect_ok = r.ok();
        var buf: [512]u8 = undefined;
        const line = r.firstLine(.err, &buf);
        s.effect_note_len = @min(line.len, s.effect_note.len);
        @memcpy(s.effect_note[0..s.effect_note_len], line[0..s.effect_note_len]);
    }
    // Re-read regardless of the verdict: a cherry-pick that conflicted, a
    // reset, a push that left us still-ahead all changed the world, and the
    // projection has to reflect what IS rather than what was asked for.
    gather();
}

/// Scratch for the `-C`-rooted argv every git invocation is rewritten into.
var rooted: Argv = .{};

/// Point a git command at THIS session's repository, by splicing `-C <root>`
/// in after the program name.
///
/// This is what replaced the `cd '<root>' || exit 0` line every command used
/// to carry. Both say the same thing; the difference is that one needed a
/// shell to say it, and a shell is what made every interpolated path a
/// quoting problem.
///
/// Deliberately NOT `exec`'s `at`. A tool entry's place would be the natural
/// home for this, but `Buffers` documents a path-backed entry's place as
/// provisional and inert until the detection provider lands — so it is not yet
/// a fact a second repository's commands can be routed by. `-C` is git's own
/// mechanism, needs no door, and is exactly as scoped as the guard it replaces.
fn rootedArgv(argv: []const []const u8) []const []const u8 {
    const root = cur().root;
    if (root.len == 0 or argv.len == 0) return argv;
    if (!std.mem.eql(u8, argv[0], "git")) return argv; // `rm` takes absolute paths
    rooted = .{};
    rooted.pushAll(&.{ "git", "-C", root });
    rooted.pushAll(argv[1..]);
    return rooted.slice();
}

/// A bounded argv for the commands whose length comes from the MODEL —
/// staging a section, discarding one. Bounded rather than allocated because
/// the ceiling is the useful part: a section of ten thousand files is a
/// different interaction, not a longer command line, and `push` says so by
/// refusing rather than by silently truncating.
pub const Argv = struct {
    items: [max_args][]const u8 = undefined,
    n: usize = 0,
    full: bool = false,

    /// One argument per file plus the verb's own words.
    pub const max_args = model.MAX_FILES + 8;

    pub fn push(self: *Argv, arg: []const u8) void {
        if (self.n == self.items.len) {
            self.full = true;
            return;
        }
        self.items[self.n] = arg;
        self.n += 1;
    }

    pub fn pushAll(self: *Argv, args: []const []const u8) void {
        for (args) |a| self.push(a);
    }

    pub fn slice(self: *const Argv) []const []const u8 {
        return self.items[0..self.n];
    }
};

/// Preserve the cursor spot across the coming re-render: capture the node
/// identity (re-found in the new model) plus the raw offset as a fallback.
pub fn markRestore() void {
    cur().restore_cursor = true;
    cur().pending_cursor = weft.cursor();
    cur().restore_target = nodeAtCursor();
}

/// Focus the named tool entry and fill it with one command's stdout — the
/// read-only views (`git log`, `git show`, a blame) that own their own buffer
/// and are never parsed into the model.
pub fn show(argv: []const []const u8, name: []const u8, style: model.ViewStyle) void {
    if (!model.focusBuffer(name)) weft.runStr("buffer-create", name);
    _ = weft.execWith(ShowOf, .{ .session = cur().id, .style = style }, .{
        .argv = rootedArgv(argv),
    }, showLanded);
}

const ShowOf = struct { session: u32, style: model.ViewStyle };

fn showLanded(r: weft.ExecDone, who: ShowOf) void {
    const s = model.sessionById(who.session) orelse return;
    model.routed = s;
    // The view buffer is whatever is focused — `show` focused it before firing
    // and a read cannot have moved it, since nothing else runs in between.
    var scratch: [1 << 16]u8 = undefined;
    const text = r.read(.out, 0, &scratch);
    weft.edit(.{ .start = 0, .end = weft.byteLen() }, text);
    weft.jump(0);
    if (model.on_view_filled) |f| f(who.style);
}
