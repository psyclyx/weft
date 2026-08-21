// dap.js — a Debug Adapter Protocol (DAP) client, as a weft JS plugin. The
// debugger's second slice: after the breakpoint MARKERS (the `debug` wasm
// plugin), this drives an actual debug session against a debug-adapter
// subprocess — launch, hit a breakpoint, see the stack, step, continue.
//
// DAP is JSON over stdio with `Content-Length` framing (not NDJSON like ACP).
// The transport (procSpawn/procSend/onOutput/procRead) and the *debug*
// transcript (bufferAppend) + status chip are the weft.* membrane; the protocol
// is plain JS. The adapter command is config data — weft.set("dap","cmd",…) —
// never baked (NixOS-friendly). Breakpoints come from the `debug` plugin's
// gutter markers via weft.breakpoints(source) — the lines you mark ARE where
// the session stops — falling back to weft.config("line") if none are set.
// `source` is the file breakpoints live in; `program` is the executable to
// launch (they differ for a compiled program, coincide for an interpreter).

const BUF = "*debug*";
const ST = { normal: 0, location: 4, emphasis: 5, muted: 6 };

let adapter = null; // proc-stream handle
let seq = 1; // DAP sequence counter
let curThread = 1; // the stopped thread, for step/continue
let inbuf = ""; // Content-Length frame accumulator

function log(text, cls) {
  weft.bufferAppend(BUF, text, cls || 0);
}
function setStatus(s) {
  weft.status(s);
}

// Send a DAP request with Content-Length framing (bytes; ASCII bodies here).
function send(command, args) {
  const body = JSON.stringify({ seq: seq++, type: "request", command, arguments: args || {} });
  weft.procSend(adapter, "Content-Length: " + body.length + "\r\n\r\n" + body);
}

function onMessage(msg) {
  if (msg.type === "event") {
    if (msg.event === "initialized") {
      // The adapter is ready for configuration: send breakpoints, then done. The
      // lines come from the `debug` plugin's gutter markers (weft.breakpoints,
      // published per SOURCE file) — the visual breakpoints ARE the session's.
      // Fall back to config `line` if nothing's been marked yet. `source` is the
      // file breakpoints live in (what the debug info names); it differs from
      // `program`, the executable to launch — for an interpreter they coincide,
      // for a compiled program they don't. Defaults to program when unset.
      const source = weft.config("source") || weft.config("program") || "program";
      const csv = weft.breakpoints(source);
      const lines = csv
        ? csv.split(",").map(function (s) { return parseInt(s, 10); }).filter(function (n) { return n > 0; })
        : [parseInt(weft.config("line") || "1", 10)];
      send("setBreakpoints", {
        source: { path: source, name: source },
        breakpoints: lines.map(function (l) { return { line: l }; }),
      });
      send("configurationDone", {});
    } else if (msg.event === "stopped") {
      const b = msg.body || {};
      curThread = b.threadId || curThread;
      setStatus("● debug · " + (b.reason || "stopped"));
      log("\n■ stopped: " + (b.reason || "?") + "\n", ST.emphasis);
      send("stackTrace", { threadId: curThread, startFrame: 0, levels: 1 });
    } else if (msg.event === "output") {
      log((msg.body && msg.body.output) || "");
    } else if (msg.event === "terminated" || msg.event === "exited") {
      setStatus("○ debug · done");
      log("\n□ program terminated\n", ST.muted);
    }
    return;
  }
  if (msg.type === "response") {
    if (!msg.success) {
      log("\n! " + msg.command + " failed: " + (msg.message || "") + "\n", ST.muted);
      return;
    }
    if (msg.command === "initialize") {
      // Capabilities in hand — launch the program (the `initialized` event that
      // follows drives breakpoints + configurationDone).
      send("launch", { program: weft.config("program") || "program", stopOnEntry: false });
    } else if (msg.command === "stackTrace") {
      const f = (msg.body && msg.body.stackFrames && msg.body.stackFrames[0]) || null;
      if (f) log("  → " + ((f.source && f.source.name) || "?") + ":" + f.line + "  " + (f.name || "") + "\n", ST.location);
    }
    return;
  }
}

// Deframe Content-Length messages from the adapter's stdout.
weft.onOutput((h) => {
  inbuf += weft.procRead(h);
  while (true) {
    const m = inbuf.match(/Content-Length: (\d+)\r?\n\r?\n/);
    if (!m) break;
    const len = parseInt(m[1], 10);
    const start = m.index + m[0].length;
    if (inbuf.length < start + len) break; // await the full body
    const body = inbuf.slice(start, start + len);
    inbuf = inbuf.slice(start + len);
    let msg;
    try {
      msg = JSON.parse(body);
    } catch (e) {
      continue;
    }
    onMessage(msg);
  }
});

// ── Commands ──────────────────────────────────────────────────────────
weft.command("debug-start", () => {
  const cmd = weft.config("cmd");
  if (!cmd) {
    weft.echo('debug: set an adapter — weft.set("dap","cmd","…")');
    return;
  }
  seq = 1;
  inbuf = "";
  log("debug: launching " + cmd + "\n", ST.muted);
  setStatus("● debug · starting");
  adapter = weft.procSpawn(cmd);
  send("initialize", {
    clientID: "weft",
    adapterID: "weft",
    linesStartAt1: true,
    columnsStartAt1: true,
    pathFormat: "path",
    supportsRunInTerminalRequest: false,
  });
  weft.echo("debug: started " + cmd);
});

function stepCmd(name, command) {
  weft.command(name, () => {
    if (adapter === null) {
      weft.echo("debug: no session — debug-start first");
      return;
    }
    send(command, { threadId: curThread });
  });
}
stepCmd("debug-continue", "continue");
stepCmd("debug-step-over", "next");
stepCmd("debug-step-into", "stepIn");
stepCmd("debug-step-out", "stepOut");

weft.command("debug-stop", () => {
  if (adapter === null) return;
  send("disconnect", { terminateDebuggee: true });
  setStatus("○ debug · stopped");
});
