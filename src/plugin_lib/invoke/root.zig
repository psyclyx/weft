//! invoke — "run this command, and ask me for what you didn't give it".
//!
//! Two doors in this editor take a command from a person: the palette (pick a
//! name) and the `:` line (type a name and some arguments). Both used to lose
//! on the same rock. The palette ran EVERY command with zero arguments, so
//! `listen`, `connect`, `grant`, `share-fs` — every command that takes
//! something — refused on arity into a discarded error and looked, from the
//! outside, exactly like a command that does nothing. The `:` line could pass
//! arguments but not ask for them, so `:listen` with the port left off did the
//! same nothing, more quietly.
//!
//! What both were missing is not a UI. It is the same three sentences:
//!
//!   1. this text names `listen`, which takes `<port> <access>`;
//!   2. you gave me one of them;
//!   3. so I will ask for the other, then run it.
//!
//! This is those three sentences, once. A door instantiates an `Invoker`,
//! splices its prompt commands into its own table, and calls `line()` — with
//! whatever the person typed, arguments or not. The asking, the argument
//! splitting, and the signature rendering are all here, so the palette and the
//! `:` line cannot drift into two different answers to "what does this take?"
//! the way three plugins once drifted into three minibuffers.
//!
//! It knows a command's shape by ASKING THE REGISTRY (`weft.commandArity` and
//! friends) — never by a table of its own. A command declared today is
//! askable today, from a plugin that has never heard of it.
//!
//! Freestanding-wasm shaped: fixed buffers per instantiation, no allocator.

const std = @import("std");
const weft = @import("weft");
const prompt = @import("weft_prompt");

/// Arguments one invocation collects — the ceiling `wl_run_argv` enforces,
/// mirrored here so a command too wide to invoke is refused with a sentence
/// instead of assembled and then rejected at the membrane.
///
/// Two is not a buffer size. `app/providers.zig`'s census gate rests on no
/// guest passing three arguments to a command, because `grammar-add` takes
/// three and opens a caller-named directory with them. Every command a person
/// invokes interactively fits; `grammar-add` is config's to call, from the
/// trusted plane, and is meant to stay there.
pub const max_args = 2;
const NAME_CAP = 128;
const ARG_CAP = 512;

pub const Config = struct {
    /// The prompt mode this invoker asks in, and the prefix of the five
    /// command names it registers. One per instantiation.
    name: []const u8,
    /// Where the argument prompt returns to. Null — right for a service — is
    /// "the entry's own resting mode"; a grammar that owns a mode names it.
    /// See `weft_prompt`'s `Config.resting` for why that distinction matters.
    resting: ?[]const u8 = null,
    /// Whether a command missing required arguments is ASKED for them. Off,
    /// it is refused with its signature instead — the same information, in one
    /// line, for someone who would rather type the whole call or not be
    /// interrupted. Doors read this from config and pass it in.
    ask: bool = true,
};

/// One invoker. Instantiate at container scope; splice `commands` into the
/// guest's own command table and call `install`/`declare` from the usual
/// places (this module never registers behind its owner's back).
pub fn Invoker(comptime cfg: Config) type {
    return struct {
        // The invocation being assembled: a command name, and the arguments
        // collected for it so far. Held across prompts, so it must outlive
        // every scratch buffer the membrane hands back.
        var name_buf: [NAME_CAP]u8 = undefined;
        var name_len: usize = 0;
        var arg_bufs: [max_args][ARG_CAP]u8 = undefined;
        var arg_lens: [max_args]usize = @splat(0);
        var filled: usize = 0;
        var need: usize = 0;
        var takes: usize = 0;
        var asking: bool = cfg.ask;

        var label_buf: [NAME_CAP + 64]u8 = undefined;
        var hint_buf: [256]u8 = undefined;
        var msg_buf: [256]u8 = undefined;

        // Resolving a name costs a scan of the registry — one membrane
        // crossing per command, a few hundred of them — and the `:` line asks
        // for a hint on EVERY keystroke. Naming that cost honestly: while the
        // command name itself is being typed, each keystroke pays the scan
        // (~a tenth of a millisecond against a full registry, an order of
        // magnitude under a frame). The head token stops changing the moment a
        // space is typed, and this cache makes every keystroke after that one
        // free — which is the half where a hint is doing the most work.
        var cached_name: [NAME_CAP]u8 = undefined;
        var cached_len: usize = 0;
        var cached_index: usize = 0;
        var cached_valid: bool = false;

        /// The argument prompt. Its accept stores one argument and either asks
        /// for the next or runs — so a two-argument command is two questions,
        /// not a syntax to get right in one line.
        pub const ask_line = prompt.Prompt(.{
            .name = cfg.name,
            .resting = cfg.resting,
            .capacity = ARG_CAP,
            // Wrapped rather than referenced directly: `onArg` reopens this
            // very prompt for the next argument, and a function body is
            // analyzed lazily where a decl reference would close the loop.
            .on_accept = struct {
                fn f(text: []const u8) void {
                    onArg(text);
                }
            }.f,
            .on_cancel = struct {
                fn f() void {
                    onCancel();
                }
            }.f,
        });

        /// The prompt's five editing commands, for the guest's own table.
        pub const commands = ask_line.commands;

        pub fn declare() void {
            ask_line.declare();
        }
        pub fn install() void {
            ask_line.install();
        }

        /// Turn asking on or off at runtime (a door's config knob). Off, a
        /// call missing arguments is refused with its signature.
        pub fn setAsk(on: bool) void {
            asking = on;
        }

        // ── Entry points ────────────────────────────────────────────────

        /// Invoke a whole typed line: `name arg…`. The arguments are split
        /// against what the command DECLARES, so the last one absorbs the rest
        /// of the line (`:llm-ask write me a poem` is one argument, `:grant fp
        /// edit` is two) instead of against a fixed guess.
        pub fn invokeLine(text: []const u8) void {
            const trimmed = trim(text);
            if (trimmed.len == 0) return;
            var i: usize = 0;
            while (i < trimmed.len and !isSpace(trimmed[i])) i += 1;
            begin(trimmed[0..i], trimLeft(trimmed[i..]));
        }

        /// Invoke a command by NAME with nothing supplied — the palette's
        /// accepted row. Identical to `line` with an empty tail; spelled
        /// separately because that is what the caller means.
        pub fn invokeName(cmd: []const u8) void {
            begin(cmd, "");
        }

        /// Signature help for a line being typed: the parameters still to
        /// come, or "" when there is nothing useful to say (an unknown or
        /// incomplete name, a call already complete). Cheap enough to call on
        /// every keystroke; safe to render straight into an echo line.
        pub fn hint(text: []const u8) []const u8 {
            const trimmed = trimLeft(text);
            var i: usize = 0;
            while (i < trimmed.len and !isSpace(trimmed[i])) i += 1;
            const head = trimmed[0..i];
            if (head.len == 0) return "";
            const idx = resolve(head) orelse return "";
            const arity = weft.commandArity(idx) orelse return "";
            if (arity == 0) return "";
            // What is left to say, which is the useful half: an argument
            // counts as supplied the moment its first character is typed, so
            // the hint names what comes AFTER the cursor rather than repeating
            // the one being written (`:listen 777 <access>`, not `:listen 777
            // <port> <access>`).
            const given = countArgs(trimmed[i..], arity);
            if (given >= arity) return "";
            var w: usize = 0;
            // The line supplies its own separator when it ends in one; two
            // spaces where the eye expects one reads as a mistake.
            var lead: []const u8 = " ";
            if (text.len > 0 and isSpace(text[text.len - 1])) lead = "";
            var k = given;
            while (k < arity) : (k += 1) {
                const pname = weft.commandArg(idx, k) orelse break;
                const optional = k >= (weft.commandArityRequired(idx) orelse arity);
                put(&hint_buf, &w, lead);
                lead = " ";
                put(&hint_buf, &w, if (optional) "[" else "<");
                put(&hint_buf, &w, pname);
                put(&hint_buf, &w, if (optional) "]" else ">");
            }
            return hint_buf[0..w];
        }

        /// A command's full shape — `listen <port> <access>` — for a palette
        /// row's detail or a refusal. Written into `out`, truncated rather
        /// than failed.
        pub fn signature(out: []u8, idx: usize, cmd: []const u8) []const u8 {
            var w: usize = 0;
            put(out, &w, cmd);
            const arity = weft.commandArity(idx) orelse 0;
            const required = weft.commandArityRequired(idx) orelse arity;
            var k: usize = 0;
            while (k < arity) : (k += 1) {
                const pname = weft.commandArg(idx, k) orelse break;
                put(out, &w, if (k >= required) " [" else " <");
                put(out, &w, pname);
                put(out, &w, if (k >= required) "]" else ">");
            }
            return out[0..w];
        }

        /// Just the parameter half — `<port> <access>` — for a row that
        /// already shows the name in its own column.
        pub fn params(out: []u8, idx: usize) []const u8 {
            const whole = signature(out, idx, "");
            return trimLeft(whole);
        }

        // ── The machine ─────────────────────────────────────────────────

        fn begin(cmd: []const u8, tail: []const u8) void {
            name_len = @min(cmd.len, name_buf.len);
            @memcpy(name_buf[0..name_len], cmd[0..name_len]);
            filled = 0;

            const idx = resolve(name_buf[0..name_len]) orelse {
                echoFmt("not an editor command: {s}", .{name_buf[0..name_len]});
                return;
            };
            const arity = weft.commandArity(idx) orelse 0;
            if (arity > max_args) {
                // Wider than a plugin may call (see `max_args`). Say so here,
                // where the command's name is still in hand, rather than
                // collecting arguments for a call that cannot be made.
                var buf: [256]u8 = undefined;
                echoFmt("{s} — only config can call this one", .{signature(&buf, idx, name_buf[0..name_len])});
                return;
            }
            takes = arity;
            need = @min(weft.commandArityRequired(idx) orelse takes, takes);

            // Split the tail against the declared arity: the last declared
            // argument absorbs the remainder, so a prose argument survives its
            // own spaces. A command that declared NOTHING but was handed a
            // tail still gets it as one argument — plenty of plugin commands
            // read an argument without having declared one, and swallowing it
            // here would be a regression dressed as a rule.
            var rest = tail;
            const room = if (takes == 0 and tail.len > 0) 1 else takes;
            while (filled < room and rest.len > 0) {
                const last = filled + 1 == room;
                var j: usize = 0;
                if (last) {
                    j = rest.len;
                } else {
                    while (j < rest.len and !isSpace(rest[j])) j += 1;
                }
                if (!store(filled, rest[0..j])) return;
                filled += 1;
                rest = trimLeft(rest[j..]);
            }

            if (filled >= need) return fire();
            if (!asking) {
                var buf: [256]u8 = undefined;
                echoFmt("{s}", .{signature(&buf, idx, name_buf[0..name_len])});
                return;
            }
            askFor(idx);
        }

        /// Ask for argument `filled`: the label names the command and the one
        /// parameter being filled; the hint trailing the typed text names what
        /// still comes after it.
        fn askFor(idx: usize) void {
            const pname = weft.commandArg(idx, filled) orelse return fire();
            var w: usize = 0;
            put(&label_buf, &w, name_buf[0..name_len]);
            put(&label_buf, &w, " <");
            put(&label_buf, &w, pname);
            put(&label_buf, &w, ">: ");
            ask_line.open(label_buf[0..w]);
        }

        fn onArg(text: []const u8) void {
            // Nothing typed for something required is a change of mind, not an
            // empty argument. Say so and stop, rather than invoking a command
            // with a blank where a port belongs.
            if (text.len == 0 and filled < need) {
                echoFmt("{s}: canceled", .{name_buf[0..name_len]});
                return;
            }
            if (!store(filled, text)) return;
            filled += 1;
            if (filled >= need or filled >= takes) return fire();
            const idx = resolve(name_buf[0..name_len]) orelse return;
            askFor(idx);
        }

        fn onCancel() void {
            filled = 0;
            name_len = 0;
        }

        /// Hand the assembled call to the one door that runs AND reports
        /// (`command.invoke`, host side) — so a refusal or an answer lands on
        /// the echo line rather than in a dropped return value.
        fn fire() void {
            var argv: [max_args][]const u8 = undefined;
            for (0..filled) |i| argv[i] = arg_bufs[i][0..arg_lens[i]];
            weft.runArgs(name_buf[0..name_len], argv[0..filled]);
        }

        /// Keep one argument, or refuse it out loud. Truncating silently is
        /// the one thing not to do here: a shortened argument is still a legal
        /// call, so it would run — against half a path, half a URL, half a
        /// prompt — and look like the command misbehaving.
        fn store(i: usize, text: []const u8) bool {
            if (i >= max_args) return false;
            if (text.len > ARG_CAP) {
                echoFmt("{s}: that argument is too long ({d} > {d} bytes)", .{ name_buf[0..name_len], text.len, ARG_CAP });
                return false;
            }
            arg_lens[i] = text.len;
            @memcpy(arg_bufs[i][0..text.len], text);
            return true;
        }

        /// This command's index in the registry, or null. Cached on the name,
        /// because the `:` line resolves once per keystroke.
        fn resolve(cmd: []const u8) ?usize {
            if (cached_valid and cached_len == cmd.len and
                std.mem.eql(u8, cached_name[0..cached_len], cmd)) return cached_index;
            const n = weft.commandCount();
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const cn = weft.commandName(i) orelse continue;
                if (!std.mem.eql(u8, cn, cmd)) continue;
                cached_len = @min(cmd.len, cached_name.len);
                @memcpy(cached_name[0..cached_len], cmd[0..cached_len]);
                cached_index = i;
                cached_valid = true;
                return i;
            }
            return null;
        }

        /// How many arguments a tail already supplies, splitting the way
        /// `begin` will — the last declared argument absorbs the rest of the
        /// line, so once the cursor is inside it nothing further is owed.
        fn countArgs(tail: []const u8, arity: usize) usize {
            var n: usize = 0;
            var rest = tail;
            while (n < arity) {
                rest = trimLeft(rest);
                if (rest.len == 0) return n; // nothing typed for this one yet
                n += 1;
                if (n == arity) return n; // the last one takes the rest
                var j: usize = 0;
                while (j < rest.len and !isSpace(rest[j])) j += 1;
                rest = rest[j..];
            }
            return n;
        }

        fn echoFmt(comptime fmt: []const u8, args: anytype) void {
            weft.echo(std.fmt.bufPrint(&msg_buf, fmt, args) catch return);
        }
    };
}

// ── Small helpers (shared by every instantiation) ───────────────────────
fn put(buf: []u8, at: *usize, s: []const u8) void {
    const n = @min(s.len, buf.len - at.*);
    @memcpy(buf[at.* .. at.* + n], s[0..n]);
    at.* += n;
}
fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}
fn trimLeft(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and isSpace(s[i])) i += 1;
    return s[i..];
}
fn trim(s: []const u8) []const u8 {
    var a = trimLeft(s);
    while (a.len > 0 and isSpace(a[a.len - 1])) a = a[0 .. a.len - 1];
    return a;
}
