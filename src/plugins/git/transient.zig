//! git — the flag transients (push/pull/fetch), DECLARED.
//!
//! This file used to be 131 lines: three mode names, three `render*Surface`
//! functions painting the same three-column layout, six toggle commands each
//! flipping a boolean and repainting, three `-do` commands each remembering to
//! close the surface first, and a cancel that set the mode back to a hardcoded
//! `"git"`. `root.zig` carried another ~25 lines of bindings for them.
//!
//! What is left is the part that is actually about git: which flags exist, and
//! what argv they build. Everything else was `weft.transient`'s job all along
//! (`plugin_sdk/transient.zig`) — including the two bugs the hand-written
//! version had: `q` cancelled push but not the commit dispatch, and cancelling
//! from a non-git buffer left you in git's keymap.

const weft = @import("weft");
const gather_mod = @import("gather.zig");
const after = gather_mod.after;
const Argv = gather_mod.Argv;

/// Every flag menu leaves the same way, and `q` is one of them here — the
/// habit every version-control UI shares, and the one push had but the commit
/// dispatch did not.
const leave_keys: []const []const u8 = &.{ "Escape", "C-g", "q" };

pub const push = weft.transient("git-push", .{
    .title = "Push",
    .switches = &.{
        .{ .key = "f", .flag = "--force-with-lease" },
        .{ .key = "u", .flag = "--set-upstream", .extra = &.{ "origin", "HEAD" } },
    },
    .actions = &.{.{ .keys = &.{ "p", "Return" }, .label = "push", .run = doPush }},
    .cancel_keys = leave_keys,
});

pub const pull = weft.transient("git-pull", .{
    .title = "Pull",
    .switches = &.{.{ .key = "r", .flag = "--rebase" }},
    .actions = &.{.{ .keys = &.{ "p", "Return" }, .label = "pull", .run = doPull }},
    .cancel_keys = leave_keys,
});

pub const fetch = weft.transient("git-fetch", .{
    .title = "Fetch",
    .switches = &.{
        .{ .key = "a", .flag = "--all" },
        .{ .key = "p", .flag = "--prune" },
    },
    .actions = &.{.{ .keys = &.{ "f", "Return" }, .label = "fetch", .run = doFetch }},
    .cancel_keys = leave_keys,
});

/// The three commands' one shape: a base argv, whatever is armed, and a
/// re-gather. `procToBuffer` captures only stdout, so op output is suppressed
/// for a clean re-gather — the post-op git state IS the feedback; hard errors
/// surface via the host log (see `report`).
fn run(comptime t: type, base: []const []const u8, saying: []const u8) void {
    var argv: Argv = .{};
    argv.pushAll(base);
    t.appendTo(&argv);
    weft.echo(saying);
    after(argv.slice());
}

fn doPush() void {
    run(push, &.{ "git", "push" }, "pushing…");
}
fn doPull() void {
    run(pull, &.{ "git", "pull" }, "pulling…");
}
fn doFetch() void {
    run(fetch, &.{ "git", "fetch" }, "fetching…");
}

// ── The plain ACTION menus: no flags, just verbs git already has ────────────
//
// These were five near-identical blocks of `menuMode` + one `bindKey` per verb
// + two cancel bindings. They are the same declaration as the three above with
// `switches` left out — which is the whole claim `weft.transient` makes: a menu
// with flags and a menu without are one thing, and only one of them needed a
// boolean.
//
// Every action here NAMES an existing command, so nothing is generated for it
// and the key binds straight through. git's dispatch funnel sees the verb's own
// table entry, with the route and scope it was declared with — a wrapper would
// have taken the defaults and quietly routed `git-stash-drop` as if it were
// durable.

pub const commit = weft.transient("git-commit-dispatch", .{
    .title = "Commit",
    .actions = &.{
        // An INTENTION, not a command: `c` means "commit here", and what that
        // resolves to is the intent plane's answer. A one-shot menu binds it
        // through untouched — the §5.1 spelling IS the reference.
        .{ .keys = &.{"c"}, .label = "commit", .command = "plugin.git.commit" },
        .{ .keys = &.{"a"}, .label = "amend", .command = "git-amend" },
        .{ .keys = &.{"e"}, .label = "extend", .command = "git-extend" },
        .{ .keys = &.{"w"}, .label = "reword", .command = "git-reword" },
        .{ .keys = &.{"f"}, .label = "fixup", .command = "git-fixup" },
        .{ .keys = &.{"s"}, .label = "squash", .command = "git-squash" },
    },
});

pub const reset = weft.transient("git-reset", .{
    .title = "Reset",
    .actions = &.{
        .{ .keys = &.{"s"}, .label = "soft", .command = "git-reset-soft" },
        .{ .keys = &.{"m"}, .label = "mixed", .command = "git-reset-mixed" },
        .{ .keys = &.{"h"}, .label = "hard", .command = "git-reset-hard" },
    },
});

pub const branch = weft.transient("git-branch", .{
    .title = "Branch",
    .actions = &.{
        .{ .keys = &.{"b"}, .label = "checkout", .command = "git-branch-checkout" },
        .{ .keys = &.{"c"}, .label = "create", .command = "git-branch-create" },
        .{ .keys = &.{"n"}, .label = "new", .command = "git-branch-new" },
        .{ .keys = &.{"d"}, .label = "delete", .command = "git-branch-delete" },
        .{ .keys = &.{"r"}, .label = "rename", .command = "git-branch-rename" },
    },
});

pub const stash = weft.transient("git-stash", .{
    .title = "Stash",
    .actions = &.{
        .{ .keys = &.{"z"}, .label = "save", .command = "git-stash-save" },
        .{ .keys = &.{"p"}, .label = "pop", .command = "git-stash-pop" },
        .{ .keys = &.{"a"}, .label = "apply", .command = "git-stash-apply" },
        .{ .keys = &.{"l"}, .label = "list", .command = "git-stash-list" },
        .{ .keys = &.{"k"}, .label = "drop", .command = "git-stash-drop" },
    },
});

// `git-log-choose`, not `git-log`: the derived open command would collide with
// git's own `git-log` verb, which this menu's first key runs. The one place a
// transient's name is not free is where the plugin already used it.
pub const log = weft.transient("git-log-choose", .{
    .title = "Log",
    .actions = &.{
        .{ .keys = &.{"l"}, .label = "this branch", .command = "git-log" },
        .{ .keys = &.{"a"}, .label = "all branches", .command = "git-log-all" },
    },
});

/// Bind every menu. Called from git's `init`, after the manifest registered the
/// commands these bindings name.
pub fn install() void {
    push.install();
    pull.install();
    fetch.install();
    commit.install();
    reset.install();
    branch.install();
    stash.install();
    log.install();
}

/// The generated entries, for splicing into git's own table.
pub const commands = push.commands ++ pull.commands ++ fetch.commands ++
    commit.commands ++ reset.commands ++ branch.commands ++
    stash.commands ++ log.commands;

/// Leave `git-rebase-menu`, the one menu still hand-written: it is STICKY
/// without having any flags (an `i` mid-rebase re-sets the same mode to keep it
/// open), which is the one shape `weft.transient` does not derive. Kept honest
/// rather than forced — but it no longer names a mode to return to.
pub fn gitMenuCancel() void {
    weft.surfaceClose();
    weft.exitToResting();
}
