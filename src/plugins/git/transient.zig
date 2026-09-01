//! git — TRANSIENTS: the flag menus.
//!
//! push/pull/fetch each open a sticky menu mode and paint their own corner
//! surface listing the flags you can toggle and the key that runs it. The
//! flags live on the session (two repositories can each have their own
//! `--force` armed); everything else here is presentation, which is why it
//! reads as one small file rather than 120 lines in the middle of the verbs.

const weft = @import("weft");
const model = @import("model.zig");
const std = @import("std");
const cur = model.cur;
const gather_mod = @import("gather.zig");
const after = gather_mod.after;
const Argv = gather_mod.Argv;

// ── push/pull/fetch: flag transients (sticky menu + our own surface) ─────────
// Flags accumulate in globals; a single key executes. On execute we refresh
// *git* (the branch header's ahead/behind reflects the result) rather than
// dumping normal output. NOTE: `procToBuffer` captures only stdout, so op
// output is suppressed for a clean re-gather — the post-op git state IS the
// feedback; hard errors surface via the host log, not a buffer (see report).
pub fn flagRow(key: []const u8, label: []const u8, on: bool) void {
    weft.surfaceRow();
    weft.surfaceSpan(key, .accent);
    weft.surfaceSpan(label, .leaf);
    weft.surfaceSpan(if (on) "on" else "off", if (on) .effect else .muted);
}
pub fn actRow(key: []const u8, label: []const u8) void {
    weft.surfaceRow();
    weft.surfaceSpan(key, .accent);
    weft.surfaceSpan(label, .leaf);
}

pub fn gitPush() void {
    cur().push_force = false;
    cur().push_upstream = false;
    weft.setMode("git-push-menu");
    renderPushSurface();
}
pub fn renderPushSurface() void {
    weft.surfaceBegin(.corner);
    weft.surfaceRow();
    weft.surfaceSpan("Push", .accent);
    flagRow("f", "--force-with-lease", cur().push_force);
    flagRow("u", "--set-upstream", cur().push_upstream);
    actRow("p", "push");
    weft.surfaceEnd(-1);
}
pub fn gitPushToggleForce() void {
    cur().push_force = !cur().push_force;
    renderPushSurface();
}
pub fn gitPushToggleUpstream() void {
    cur().push_upstream = !cur().push_upstream;
    renderPushSurface();
}
pub fn gitPushDo() void {
    weft.surfaceClose();
    // The flags ARE the argv now — where they used to be words appended to a
    // string that a shell would later have to split back apart.
    var argv: Argv = .{};
    argv.pushAll(&.{ "git", "push" });
    if (cur().push_force) argv.push("--force-with-lease");
    if (cur().push_upstream) argv.pushAll(&.{ "--set-upstream", "origin", "HEAD" });
    weft.echo("pushing…");
    after(argv.slice());
}

pub fn gitPull() void {
    cur().pull_rebase = false;
    weft.setMode("git-pull-menu");
    renderPullSurface();
}
pub fn renderPullSurface() void {
    weft.surfaceBegin(.corner);
    weft.surfaceRow();
    weft.surfaceSpan("Pull", .accent);
    flagRow("r", "--rebase", cur().pull_rebase);
    actRow("p", "pull");
    weft.surfaceEnd(-1);
}
pub fn gitPullToggleRebase() void {
    cur().pull_rebase = !cur().pull_rebase;
    renderPullSurface();
}
pub fn gitPullDo() void {
    weft.surfaceClose();
    weft.echo("pulling…");
    if (cur().pull_rebase) after(&.{ "git", "pull", "--rebase" }) else after(&.{ "git", "pull" });
}

pub fn gitFetch() void {
    cur().fetch_all = false;
    cur().fetch_prune = false;
    weft.setMode("git-fetch-menu");
    renderFetchSurface();
}
pub fn renderFetchSurface() void {
    weft.surfaceBegin(.corner);
    weft.surfaceRow();
    weft.surfaceSpan("Fetch", .accent);
    flagRow("a", "--all", cur().fetch_all);
    flagRow("p", "--prune", cur().fetch_prune);
    actRow("f", "fetch");
    weft.surfaceEnd(-1);
}
pub fn gitFetchToggleAll() void {
    cur().fetch_all = !cur().fetch_all;
    renderFetchSurface();
}
pub fn gitFetchTogglePrune() void {
    cur().fetch_prune = !cur().fetch_prune;
    renderFetchSurface();
}
pub fn gitFetchDo() void {
    weft.surfaceClose();
    var argv: Argv = .{};
    argv.pushAll(&.{ "git", "fetch" });
    if (cur().fetch_all) argv.push("--all");
    if (cur().fetch_prune) argv.push("--prune");
    weft.echo("fetching…");
    after(argv.slice());
}
pub fn gitMenuCancelSurface() void {
    weft.surfaceClose();
    weft.setMode("git");
}
pub fn gitMenuCancel() void {
    weft.setMode("git");
}
