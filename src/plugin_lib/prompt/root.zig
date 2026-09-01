//! prompt — "ask the user for one line", once.
//!
//! Three plugins had grown three different answers to the same question, with
//! three different feels and three different cancel semantics:
//!
//!   - `ex` typed into a static buffer re-echoed on the bottom line;
//!   - `git` opened a REAL BUFFER (`*git-input*`) with its own mode and its
//!     own abort/resume/finish commands, then read line one back out of the
//!     document;
//!   - `lsp` opened the FUZZY PICKER with an empty item list and took the
//!     free-text accept — a text field spelled as a search.
//!
//! A user who cancels a rename and cancels a branch name should not be
//! learning two different keys, and a plugin that wants a line of text should
//! not be choosing a UI. This is that one primitive: the echo-line minibuffer
//! `ex` already proved, generalized, so it costs a plugin five command
//! registrations and a callback.
//!
//! It needs NO new core door — it composes `textInput` (a mode whose printable
//! keys route to a command), `setMode`, and `echo`, exactly as vim's `f`/`t`
//! already do. Rendering is the echo line, so a colorscheme and a status line
//! get it for free and no plugin has to own an overlay for it.
//!
//! Freestanding-wasm shaped: a fixed line buffer per instantiation, no
//! allocator. Each guest is its own wasm module, so two plugins' prompts never
//! share the buffer below even though they share this source.

const std = @import("std");
const weft = @import("weft");

pub const Config = struct {
    /// The keymap mode this prompt runs in, and the prefix of the five
    /// command names it registers (`<name>-type`, `-backspace`, `-clear`,
    /// `-accept`, `-cancel`). One string, so a mode and its commands cannot
    /// drift apart.
    name: []const u8,
    /// Where Enter and Escape land.
    ///
    /// Null — the right answer for a SERVICE plugin — means "the entry's own
    /// declared resting mode" (`weft.exitToResting`). `lsp` renames a symbol
    /// in whatever grammar you use; naming a mode there would strand a helix
    /// or emacs user in vim's `normal`, which is the mode-leak class exactly.
    /// A GRAMMAR that owns the mode (vim's `:`) names it, because for that
    /// one the answer really is a specific mode.
    resting: ?[]const u8 = null,
    /// What to do with the accepted line, when every opening of this prompt
    /// means the same thing. Called AFTER the resting mode is restored and the
    /// prompt is closed, so a handler is free to open another prompt (git's
    /// `branch -d` → confirm) without fighting itself for the mode.
    ///
    /// Null when the callers use `openWith` instead — see its doc. A prompt
    /// with neither is a prompt whose answer goes nowhere, and is refused at
    /// compile time.
    on_accept: ?*const fn (line: []const u8) void = null,
    /// What to do when the user backs out. Default: nothing but the echo
    /// line clearing — cancelling is not an event most callers have work for.
    on_cancel: ?*const fn () void = null,
    /// Longest line accepted. Overflow is refused out loud, never truncated
    /// silently into a shorter branch name than the user typed.
    capacity: usize = 1024,
    /// Say so when EVERY opening carries its own continuation (`openWith`), so
    /// leaving `on_accept` null is a decision rather than an omission.
    payload_callers: bool = false,
    /// Room for one `openWith` payload. The default holds anything a verb
    /// plausibly carries (a target, an id, a small enum); a caller wanting more
    /// says so and gets a bound, not a heap.
    payload_capacity: usize = 64,
    /// An optional trailing HINT, recomputed from the line on every keystroke
    /// and rendered dimly after it. This is where signature help lives: the
    /// `:` line hands back the parameters a typed command still wants
    /// (`:listen 7777` → ` <access>`), so the shape of the call is visible
    /// while you make it rather than in a refusal after it.
    ///
    /// A hook, not a feature: the prompt knows nothing about commands. It
    /// asks its owner what to trail the line with, and its owner — which does
    /// know — answers. Return "" for nothing to say.
    hint: ?*const fn (line: []const u8) []const u8 = null,
};

/// One of the five commands a prompt answers to. Named at MODULE scope, not
/// inside `Prompt`, so two instantiations' tables share a type and a plugin
/// holding several prompts can concatenate them into one flat command table.
pub const Command = struct { name: []const u8, handler: *const fn () void };

/// One prompt. Instantiate at container scope (`const rename = Prompt(.{…});`)
/// — the state below is per-instantiation, so a plugin may hold several.
pub fn Prompt(comptime cfg: Config) type {
    return struct {
        const Self = @This();

        comptime {
            if (cfg.on_accept == null and !cfg.payload_callers)
                @compileError(cfg.name ++ ": a prompt needs `on_accept`, or `payload_callers = true` if every opening uses `openWith`");
        }

        var buf: [cfg.capacity]u8 = undefined;
        var len: usize = 0;
        var label_buf: [128]u8 = undefined;
        var label_len: usize = 0;
        var open_now: bool = false;

        /// One opening's payload, inline. There is at most one prompt open at a
        /// time (opening a second replaces the first), so this needs no
        /// allocator and no slot table — unlike `ask`, where two questions
        /// really can be in flight.
        const payload_capacity = cfg.payload_capacity;
        /// Over-aligned to `@alignOf(u128)` so any ordinary payload — a struct
        /// of slices, an enum, a packed id — can be stored in place. A payload
        /// needing more says so at compile time rather than being misaligned at
        /// run time.
        const payload_align = @alignOf(u128);
        const Payload = [payload_capacity]u8;
        var payload_store: Payload align(payload_align) = undefined;
        var pending: ?*const fn (line: []const u8, held: *align(payload_align) const Payload) void = null;
        /// Label + line + whatever `cfg.hint` trails it with.
        var render_buf: [cfg.capacity + label_buf.len + hint_cap]u8 = undefined;
        const hint_cap = 256;

        /// The five commands this prompt answers to. A plugin splices them
        /// into its own command table rather than this module registering
        /// behind its back — one place still owns "what commands do I have".
        pub const commands = [_]Command{
            .{ .name = cfg.name ++ "-type", .handler = onType },
            .{ .name = cfg.name ++ "-backspace", .handler = onBackspace },
            .{ .name = cfg.name ++ "-clear", .handler = onClear },
            .{ .name = cfg.name ++ "-accept", .handler = onAccept },
            .{ .name = cfg.name ++ "-cancel", .handler = onCancel },
        };

        /// Bind the mode: printable keys commit through `-type`, Enter
        /// accepts, Escape and C-c back out, C-u clears. Call from `init`,
        /// after registering `commands`.
        ///
        /// The keys are NOT configurable here on purpose: "how do I get out
        /// of a prompt" is exactly the thing that should be the same in every
        /// prompt in the editor. A config that disagrees rebinds the mode.
        pub fn install() void {
            weft.textInput(cfg.name, cfg.name ++ "-type");
            weft.bindKey(cfg.name, "Return", cfg.name ++ "-accept");
            weft.bindKey(cfg.name, "KP_Enter", cfg.name ++ "-accept");
            weft.bindKey(cfg.name, "BackSpace", cfg.name ++ "-backspace");
            weft.bindKey(cfg.name, "Escape", cfg.name ++ "-cancel");
            weft.bindKey(cfg.name, "C-c", cfg.name ++ "-cancel");
            weft.bindKey(cfg.name, "C-u", cfg.name ++ "-clear");
        }

        /// Declare the five command names (call from `describe`).
        pub fn declare() void {
            inline for (commands) |c| weft.declareCommand(c.name);
        }

        /// Ask. `label` is shown before the text ("rename to: ").
        pub fn open(label: []const u8) void {
            openSeeded(label, "");
        }

        /// Ask, pre-filled — for "edit this existing value", where making the
        /// user retype what is already true is just a way to lose it.
        pub fn openSeeded(label: []const u8, seed: []const u8) void {
            pending = null;
            begin(label, seed);
        }

        /// Ask, carrying WHAT THE ANSWER IS FOR — the same shape as
        /// `weft.confirmWith`, and for the same reason.
        ///
        /// A prompt with one `on_accept` forces every caller through one
        /// callback, so a plugin asking six different questions has to stash an
        /// enum before opening and switch on it coming back. git had exactly
        /// that (`InputAction`, `input_action` on the session, and an
        /// `onInput` switch) — a demux whose only job was to undo the fact that
        /// the question and its purpose travelled separately.
        ///
        /// Here they travel together. The payload is copied into the prompt's
        /// own storage, so it does not have to outlive the call that opened it,
        /// and it is bounded: a payload larger than `payload_capacity` is a
        /// compile error rather than a silent truncation of the thing an answer
        /// is about.
        pub fn openWith(
            comptime T: type,
            payload: T,
            label: []const u8,
            comptime on_answer: fn (line: []const u8, held: T) void,
        ) void {
            comptime {
                if (@sizeOf(T) > payload_capacity)
                    @compileError(cfg.name ++ ": payload " ++ @typeName(T) ++ " exceeds payload_capacity");
                if (@alignOf(T) > payload_align)
                    @compileError(cfg.name ++ ": payload " ++ @typeName(T) ++ " is over-aligned");
            }
            const Shim = struct {
                fn call(line: []const u8, raw: *align(payload_align) const Payload) void {
                    on_answer(line, @as(*const T, @ptrCast(@alignCast(raw))).*);
                }
            };
            payload_store = undefined;
            @as(*T, @ptrCast(@alignCast(&payload_store))).* = payload;
            pending = Shim.call;
            begin(label, "");
        }

        fn begin(label: []const u8, seed: []const u8) void {
            label_len = @min(label.len, label_buf.len);
            @memcpy(label_buf[0..label_len], label[0..label_len]);
            len = @min(seed.len, buf.len);
            @memcpy(buf[0..len], seed[0..len]);
            open_now = true;
            render();
            weft.setMode(cfg.name);
        }

        /// The text typed so far. Borrows the line buffer — copy before
        /// anything reopens the prompt.
        pub fn text() []const u8 {
            return buf[0..len];
        }

        pub fn active() bool {
            return open_now;
        }

        /// Close without running either callback — for a caller that decided
        /// the question is moot (its session died, its buffer closed).
        pub fn close() void {
            if (!open_now) return;
            open_now = false;
            len = 0;
            pending = null;
            weft.echo("");
            leave();
        }

        pub fn onType() void {
            if (!open_now) return;
            const s = weft.argStr(0) orelse return;
            if (s.len == 0) return;
            if (len + s.len > buf.len) {
                weft.echo(cfg.name ++ ": line too long");
                return;
            }
            @memcpy(buf[len .. len + s.len], s);
            len += s.len;
            render();
        }

        /// Backspace on an empty line backs OUT (vim's command line, and the
        /// thing every muscle memory expects).
        pub fn onBackspace() void {
            if (!open_now) return;
            if (len == 0) return onCancel();
            var n: usize = 1;
            while (len - n > 0 and (buf[len - n] & 0xc0) == 0x80) n += 1; // utf8 tail
            len -= n;
            render();
        }

        pub fn onClear() void {
            if (!open_now) return;
            len = 0;
            render();
        }

        /// Enter: restore the mode and clear the prompt FIRST, then hand the
        /// line over. A handler that opens another prompt, echoes a result,
        /// or fails loudly is then writing onto a clean slate instead of
        /// racing this one's teardown.
        pub fn onAccept() void {
            if (!open_now) return;
            const line = std.mem.trim(u8, buf[0..len], " \t\r");
            var held: [cfg.capacity]u8 = undefined;
            @memcpy(held[0..line.len], line);
            const n = line.len;
            open_now = false;
            len = 0;
            leave();
            weft.echo("");
            // The opening's own continuation wins, and is cleared BEFORE it
            // runs: a handler that opens this prompt again must not have its
            // new payload overwritten by this one's teardown.
            const cont = pending;
            pending = null;
            if (cont) |f| f(held[0..n], &payload_store) else if (cfg.on_accept) |f| f(held[0..n]);
        }

        pub fn onCancel() void {
            if (!open_now) return;
            open_now = false;
            len = 0;
            pending = null;
            weft.echo("");
            leave();
            if (cfg.on_cancel) |f| f();
        }

        /// Put the user back where they were. A grammar that owns the mode
        /// names it; everyone else asks the ENTRY what it rests in, so a
        /// prompt opened over a helix buffer, an emacs buffer or a files
        /// projection lands in that one's resting mode rather than a mode
        /// this library picked.
        fn leave() void {
            if (cfg.resting) |m| weft.setMode(m) else weft.exitToResting();
        }

        fn render() void {
            var w: usize = 0;
            @memcpy(render_buf[0..label_len], label_buf[0..label_len]);
            w += label_len;
            @memcpy(render_buf[w .. w + len], buf[0..len]);
            w += len;
            if (cfg.hint) |ask| {
                const h = ask(buf[0..len]);
                const n = @min(h.len, render_buf.len - w);
                @memcpy(render_buf[w .. w + n], h[0..n]);
                w += n;
            }
            weft.echo(render_buf[0..w]);
        }
    };
}
