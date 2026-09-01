//! region — embedded-region marking, a `.wasm` plugin. `mark-region` claims
//! the current line as a subbuffer tagged with a language fact — the substrate an
//! html-with-embedded-js / markdown-code-fence plugin uses to give a range
//! its own grammar. Exercises the subbuffer handle across the membrane: claim
//! returns an opaque handle the guest holds, then attaches a fact to it.

const weft = @import("weft");

const cmds = [_]weft.CommandEntry{
    .{
        .name = "mark-region",
        .call = weft.thunk(markRegion),
        .params = "[language]",
        .summary = "Mark this line as a region of another language (default text).",
    },
};
comptime {
    weft.plugin(&cmds, .{}).exportAll();
}

/// The language fact is the optional first argument, and it is OURS for the
/// duration of the call — it used to be a slice into the shim's arg scratch,
/// still live across two more host calls before `subbufferPutFact` read it.
fn markRegion(language: ?[]const u8) void {
    const lang = language orelse "text";
    const line = weft.lineAt(weft.cursor());
    const handle = weft.claimSubbuffer(line.start, line.end) orelse return;
    weft.subbufferPutFact(handle, "language", lang);
    weft.setResultInt(@intCast(line.end - line.start));
}
