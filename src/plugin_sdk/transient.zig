//! A TRANSIENT — a flag menu, as a value.
//!
//! A transient is a sticky menu that holds ARGUMENTS: some keys toggle a flag,
//! some keys run a command with whatever is armed, and one closes it. Every
//! plugin that wanted one wrote the same five pieces by hand — a mode
//! declaration, a binding per key, a boolean per switch, a `render*Surface`
//! that paints the state, and a cancel that has to remember to close the
//! surface as well as leave the mode. git wrote them three times
//! (push/pull/fetch, `transient.zig`, 131 lines plus ~60 binding lines), and
//! its other four menus are the same shape with the switches left out.
//!
//! Here it is one declaration:
//!
//! ```zig
//! const push = weft.transient("git-push", .{
//!     .title = "Push",
//!     .switches = &.{
//!         .{ .key = "f", .flag = "--force-with-lease" },
//!         .{ .key = "u", .flag = "--set-upstream", .extra = &.{ "origin", "HEAD" } },
//!     },
//!     .actions = &.{.{ .key = "p", .label = "push", .run = doPush }},
//! });
//! ```
//!
//! …contributing `push.commands` to the plugin's table and `push.install()` to
//! its init. `doPush` reads what is armed through `push.appendTo(&argv)`.
//!
//! **No new host door.** The mode, the bindings, the sticky-menu semantics and
//! the surface are all doors that already existed; what was missing was
//! anything that made writing them once enough. Keeping this in the SDK is the
//! point rather than an economy: core has no opinion about flag menus, so a
//! plugin can have a different one without asking core's permission.
//!
//! The toggles are ORDINARY COMMANDS with readable names
//! (`git-push-toggle-force-with-lease`), which means the palette can reach
//! them and a keymap can bind them outside the menu. That falls out of not
//! inventing a hidden-command concept to avoid it.

const std = @import("std");
const weft = @import("root.zig");
const Entry = @import("plugin.zig").Entry;

/// One toggleable flag. `extra` is spliced in after `flag` when armed, for the
/// flags that take an operand (`--set-upstream origin HEAD`).
pub const Switch = struct {
    key: []const u8,
    flag: []const u8,
    extra: []const []const u8 = &.{},
    /// Shown instead of `flag` when the flag is not the clearest label.
    label: []const u8 = "",
    /// Armed when the menu opens. Most transients start clean; this is for the
    /// flag whose absence is the surprising choice.
    default: bool = false,
};

/// One thing the menu DOES — named EITHER as a function to generate a command
/// for, or as a command that already exists.
///
/// `run` is for the action that reads the armed switches, because what to do
/// with `--force-with-lease` is the plugin's business and it needs a body.
///
/// `command` is for the far more common case: a menu whose keys reach verbs the
/// plugin already has. Then the key binds STRAIGHT to that command — no
/// generated wrapper — which matters beyond tidiness. A plugin's own dispatch
/// prologue (git's `before` hook routes by table index) would see the wrapper's
/// entry, not the verb's, and quietly route it wrong. Naming the command means
/// there is nothing in between to be wrong.
pub const Action = struct {
    /// Every key that runs it. The first is what the menu SHOWS; the rest are
    /// aliases (`Return` alongside the mnemonic letter).
    keys: []const []const u8,
    label: []const u8,
    run: ?*const fn () void = null,
    command: []const u8 = "",
};

pub const Spec = struct {
    title: []const u8,
    switches: []const Switch = &.{},
    actions: []const Action = &.{},
    /// Keys that leave. `Escape` and `C-g` unless a plugin says otherwise.
    cancel_keys: []const []const u8 = &.{ "Escape", "C-g" },
};

/// Generate the commands and the install step for one transient.
///
/// `name` is the OPEN COMMAND and the prefix every other generated name is
/// built from; the keymap MODE is `name ++ "-menu"`. The two must differ, and
/// not for tidiness: dispatch treats a key bound to a declared menu mode's NAME
/// as a menu open (`dispatchSpec`'s `.run` case), so a mode sharing its name
/// with a command shadows that command — the menu would open without the
/// surface its open command paints. Deriving one from the other makes that
/// unrepresentable rather than a rule to remember.
pub fn transient(comptime name: []const u8, comptime spec: Spec) type {
    comptime {
        if (spec.actions.len == 0) @compileError("transient '" ++ name ++ "' does nothing");
        var seen: []const []const u8 = &.{};
        for (spec.switches) |s| assertFreshKey(name, s.key, &seen);
        for (spec.actions) |a| {
            if (a.keys.len == 0) @compileError("transient '" ++ name ++ "' action '" ++ a.label ++ "' has no key");
            if ((a.run == null) == (a.command.len == 0))
                @compileError("transient '" ++ name ++ "' action '" ++ a.label ++
                    "' needs exactly one of `run` or `command`");
            for (a.keys) |k| assertFreshKey(name, k, &seen);
        }
        for (spec.cancel_keys) |k| assertFreshKey(name, k, &seen);
    }

    return struct {
        /// A menu with FLAGS has to stay open while they accumulate; a menu
        /// that is only a list of verbs does not, and the host's own leaf
        /// auto-pop already closes that one. So stickiness is not a knob — it
        /// falls out of whether there is anything to accumulate, which is also
        /// why git's flag menus were sticky and its action menus were not.
        const sticky = spec.switches.len > 0;

        /// Which switches are armed. Guest state, so it survives between
        /// openings — `open` resets it to the declared defaults, which is the
        /// behavior git's hand-written version had.
        var armed: [spec.switches.len]bool = blk: {
            var init_state: [spec.switches.len]bool = undefined;
            for (spec.switches, 0..) |s, i| init_state[i] = s.default;
            break :blk init_state;
        };

        // ── The generated commands ──────────────────────────────────────────

        /// The keymap mode this menu IS. See `transient`'s doc for why it is
        /// not `name`.
        pub const mode = name ++ "-menu";
        pub const open_command = name;
        pub const cancel_command = name ++ "-cancel";

        fn openFn() void {
            inline for (spec.switches, 0..) |s, i| armed[i] = s.default;
            weft.setMode(mode);
            paint();
        }

        /// Close the overlay and go back to whatever the ENTRY rests in —
        /// never a mode name written here. A transient does not know what it
        /// was opened over (`git-push` is reachable from the status projection
        /// and from an ordinary file), so any hardcoded return is the
        /// mode-leak: git's `gitMenuCancel` said `setMode("git")`, which
        /// stranded you in git's keymap if you had opened the menu anywhere
        /// else. `exitToResting` asks the entry, which is the one thing that
        /// knows.
        fn leave() void {
            weft.surfaceClose();
            weft.exitToResting();
        }

        fn cancelFn() void {
            leave();
        }

        /// One toggle per switch, and one runner per action, generated from the
        /// spec so the table cannot drift from the bindings.
        fn toggleFn(comptime i: usize) fn () void {
            return struct {
                fn call() void {
                    armed[i] = !armed[i];
                    paint();
                }
            }.call;
        }

        fn actionFn(comptime i: usize) fn () void {
            return struct {
                fn call() void {
                    // Leave FIRST, when this menu is one that stays open on its
                    // own: an action that opens a buffer, a picker or another
                    // menu must not have this menu's mode and surface still
                    // sitting on top of what it did. That is the mode-leak the
                    // hand-written versions each had to remember (`gitPushDo`
                    // closed the surface but `gitMenuCancel` set the mode — two
                    // halves, in two places, easy to half-do). A one-shot menu
                    // skips it: the host's leaf auto-pop is the leave, and
                    // doing it twice would pop a frame that is not ours.
                    if (sticky) leave();
                    if (spec.actions[i].run) |f| f() else weft.run(spec.actions[i].command);
                }
            }.call;
        }

        /// The entries to splice into the plugin's command table:
        /// `cmds ++ push.commands`.
        pub const commands: []const Entry = blk: {
            var out: []const Entry = &.{
                .{ .name = open_command, .call = openFn, .summary = spec.title },
                .{ .name = cancel_command, .call = cancelFn },
            };
            for (spec.switches, 0..) |s, i| {
                out = out ++ [_]Entry{.{
                    .name = toggleName(s),
                    .call = toggleFn(i),
                    .summary = "toggle " ++ s.flag ++ " for " ++ spec.title,
                }};
            }
            for (spec.actions, 0..) |a, i| {
                // A one-shot menu naming an EXISTING command generates nothing:
                // the key binds to that command and the host's auto-pop closes
                // the menu, so there is no wrapper to route around. That is the
                // whole of a plain action menu — a title, some keys, and verbs
                // the plugin already had.
                if (!needsWrapper(a)) continue;
                out = out ++ [_]Entry{.{
                    .name = actionName(a),
                    .call = actionFn(i),
                    .summary = a.label,
                }};
            }
            break :blk out;
        };

        /// Declare the mode and bind its keys. Call from the plugin's `init`
        /// hook — after `weft.plugin`'s generated `init` has registered the
        /// commands these bindings name.
        pub fn install() void {
            if (sticky) weft.stickyMenu(mode) else weft.menuMode(mode);
            inline for (spec.switches) |s| weft.bindKey(mode, s.key, toggleName(s));
            inline for (spec.actions) |a| {
                const target = comptime if (needsWrapper(a)) actionName(a) else a.command;
                inline for (a.keys) |k| weft.bindKey(mode, k, target);
            }
            inline for (spec.cancel_keys) |k| weft.bindKey(mode, k, cancel_command);
        }

        // ── Reading what is armed ───────────────────────────────────────────

        /// Is switch `flag` armed right now?
        pub fn on(comptime flag: []const u8) bool {
            return armed[indexOfFlag(flag)];
        }

        /// Append every armed flag (and its `extra` operands) to `argv`, which
        /// is anything with a `push([]const u8)` method — the caller's own
        /// bounded builder, so this module needs no allocator and no opinion
        /// about argv length.
        pub fn appendTo(argv: anytype) void {
            inline for (spec.switches, 0..) |s, i| {
                if (armed[i]) {
                    argv.push(s.flag);
                    inline for (s.extra) |x| argv.push(x);
                }
            }
        }

        // ── The surface ─────────────────────────────────────────────────────

        /// Paint the menu: a title, a row per switch with its state, a row per
        /// action. Every transient in the tree looks the same because it is
        /// literally the same code, which is the other half of what the
        /// hand-written ones cost.
        fn paint() void {
            weft.surfaceBegin(.corner);
            weft.surfaceRow();
            weft.surfaceSpan(spec.title, .accent);
            inline for (spec.switches, 0..) |s, i| {
                weft.surfaceRow();
                weft.surfaceSpan(s.key, .accent);
                weft.surfaceSpan(if (s.label.len > 0) s.label else s.flag, .leaf);
                weft.surfaceSpan(if (armed[i]) "on" else "off", if (armed[i]) .effect else .muted);
            }
            inline for (spec.actions) |a| {
                weft.surfaceRow();
                // The FIRST key only: `Return` is an alias, and listing every
                // alias turns a menu into a keymap dump.
                weft.surfaceSpan(a.keys[0], .accent);
                weft.surfaceSpan(a.label, .leaf);
            }
            weft.surfaceEnd(-1);
        }

        fn indexOfFlag(comptime flag: []const u8) usize {
            comptime {
                for (spec.switches, 0..) |s, i| {
                    if (std.mem.eql(u8, s.flag, flag)) return i;
                }
                @compileError("transient '" ++ name ++ "' has no switch " ++ flag);
            }
        }

        fn toggleName(comptime s: Switch) []const u8 {
            return name ++ "-toggle-" ++ comptime stripDashes(s.flag);
        }

        /// Named for the action's LABEL, not its key: `git-push-elsewhere` is a
        /// command someone can find, `git-push-e` is a keystroke that leaked
        /// into a name.
        ///
        /// An action that RESTATES its menu is `-do` instead, because
        /// `git-push-push` names nothing the menu did not already. That is the
        /// common case — most transients have one action, and it is the verb
        /// the menu is named for.
        fn actionName(comptime a: Action) []const u8 {
            const label = comptime kebab(a.label);
            return if (comptime restatesName(label)) name ++ "-do" else name ++ "-" ++ label;
        }

        /// Does this action need a command generated for it? Only when there is
        /// a body to hold (`run`) or a leave to do first (`sticky`).
        fn needsWrapper(comptime a: Action) bool {
            return a.run != null or sticky;
        }

        /// Does `label` just repeat the last dash-segment of the menu's name?
        fn restatesName(comptime label: []const u8) bool {
            comptime {
                const cut = std.mem.lastIndexOfScalar(u8, name, '-') orelse return std.mem.eql(u8, name, label);
                return std.mem.eql(u8, name[cut + 1 ..], label);
            }
        }
    };
}

/// `--force-with-lease` → `force-with-lease`, so a generated command name reads
/// as a command rather than as a flag that wandered into the palette.
fn stripDashes(comptime flag: []const u8) []const u8 {
    comptime var i: usize = 0;
    inline while (i < flag.len and flag[i] == '-') i += 1;
    return flag[i..];
}

/// `"push elsewhere"` → `"push-elsewhere"`. Labels are prose; command names are
/// not, and the gap is one substitution wide.
fn kebab(comptime label: []const u8) []const u8 {
    comptime var out: []const u8 = "";
    inline for (label) |c| {
        out = out ++ [_]u8{if (c == ' ') '-' else c};
    }
    return out;
}

fn assertFreshKey(comptime name: []const u8, comptime key: []const u8, comptime seen: *[]const []const u8) void {
    for (seen.*) |prior| {
        if (std.mem.eql(u8, prior, key))
            @compileError("transient '" ++ name ++ "' binds '" ++ key ++ "' twice");
    }
    seen.* = seen.* ++ [_][]const u8{key};
}
