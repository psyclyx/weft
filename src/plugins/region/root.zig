//! region — embedded-region marking, a `.wasm` plugin. `mark-region` claims
//! the current line as a subbuffer tagged with a language fact — the substrate an
//! html-with-embedded-js / markdown-code-fence plugin uses to give a range
//! its own grammar. Exercises the subbuffer handle across the membrane: claim
//! returns an opaque handle the guest holds, then attaches a fact to it.

const weft = @import("weft");

var id_mark: u32 = 0;

export fn describe() void {
    weft.describeCommand("mark-region", "[language]", "Mark this line as a region of another language (default text).");
}

export fn init() void {
    id_mark = weft.register("mark-region");
}

export fn on_command(id: u32) void {
    _ = id;
    // The language fact (first arg, defaulting to "text").
    const lang = weft.argStr(0) orelse "text";
    const line = weft.lineAt(weft.cursor());
    const handle = weft.claimSubbuffer(line.start, line.end) orelse return;
    weft.subbufferPutFact(handle, "language", lang);
    weft.setResultInt(@intCast(line.end - line.start));
}
