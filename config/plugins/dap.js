// dap.js — a Debug Adapter Protocol (DAP) client, as a weft JS plugin. The
// debugger's second slice: after the breakpoint MARKERS (the `debug` wasm
// plugin), this drives an actual debug session against a debug-adapter
// subprocess — launch, hit a breakpoint, see the stack, step, continue.
//
// DAP is JSON over stdio with `Content-Length` framing (not NDJSON like ACP).
// The transport (procSpawn/procSend/onOutput/procRead) and the transcript
// (bufferAppend) + status chip are the weft.* membrane; the protocol is plain
// JS. The adapter command is config data — weft.set("dap","cmd",…) — never
// baked (NixOS-friendly). Breakpoints come from the `debug` plugin's gutter
// markers via weft.breakpoints(source) — the lines you mark ARE where the
// session stops — falling back to weft.config("line") if none are set.
// `source` is the file breakpoints live in; `program` is the executable to
// launch (they differ for a compiled program, coincide for an interpreter).
//
// SESSIONS ARE INSTANCED. A debug session is a thing you have several of (two
// programs, two adapters), so each one is a record — its own adapter handle,
// sequence counter, stopped thread, frame accumulator, and program/source —
// owning its own buffer: `*debug*`, `*debug:2*`, … The buffer name IS the
// session's identity (the repl/console/llm and git-repo idiom, weft.zig's
// `Instances`). A command routes to the session whose buffer is FOCUSED, else
// the most recent, so `debug-stop` stops the one you are looking at and leaves
// the other running. `program`/`source`/`line` are snapshotted from config at
// START, never re-read: a session's target cannot change under it.

const BASE = "debug";
const MAX_SESSIONS = 64;
const ST = { normal: 0, location: 4, emphasis: 5, muted: 6 };

const sessions = []; // live sessions, most-recently-started last
let recent = null; // the session a command falls back to

function instanceName(n) {
  return n <= 1 ? "*" + BASE + "*" : "*" + BASE + ":" + n + "*";
}

// The lowest instance name no live session holds — a stopped session's buffer
// stays readable, but its name is free again.
function freeName() {
  for (let n = 1; n <= MAX_SESSIONS; n++) {
    const name = instanceName(n);
    if (!sessions.some((s) => s.buf === name)) return name;
  }
  return null;
}

function log(s, text, cls) {
  weft.bufferAppend(s.buf, text, cls || 0);
}

// The chip names the session, so two running debuggers are told apart.
function setStatus(s, state) {
  weft.status("● " + s.buf + " · " + state);
}

// The session this command is about: the one owning the focused buffer, else
// the most recent.
function current() {
  const active = weft.activeBuffer();
  const focused = sessions.find((s) => s.buf === active);
  if (focused) {
    recent = focused;
    return focused;
  }
  return recent;
}

function byHandle(h) {
  return sessions.find((s) => s.adapter === h) || null;
}

function retire(s) {
  const i = sessions.indexOf(s);
  if (i >= 0) sessions.splice(i, 1);
  if (recent === s) recent = sessions.length ? sessions[sessions.length - 1] : null;
}

// Send a DAP request with Content-Length framing (bytes; ASCII bodies here).
function send(s, command, args) {
  const body = JSON.stringify({ seq: s.seq++, type: "request", command, arguments: args || {} });
  weft.procSend(s.adapter, "Content-Length: " + body.length + "\r\n\r\n" + body);
}

function onMessage(s, msg) {
  if (msg.type === "event") {
    if (msg.event === "initialized") {
      // The adapter is ready for configuration: send breakpoints, then done. The
      // lines come from the `debug` plugin's gutter markers (weft.breakpoints,
      // published per SOURCE file) — the visual breakpoints ARE the session's.
      // Fall back to config `line` if nothing's been marked yet.
      const csv = weft.breakpoints(s.source);
      const lines = csv
        ? csv.split(",").map(function (x) { return parseInt(x, 10); }).filter(function (n) { return n > 0; })
        : [s.line];
      send(s, "setBreakpoints", {
        source: { path: s.source, name: s.source },
        breakpoints: lines.map(function (l) { return { line: l }; }),
      });
      send(s, "configurationDone", {});
    } else if (msg.event === "stopped") {
      const b = msg.body || {};
      s.thread = b.threadId || s.thread;
      setStatus(s, b.reason || "stopped");
      log(s, "\n■ stopped: " + (b.reason || "?") + "\n", ST.emphasis);
      send(s, "stackTrace", { threadId: s.thread, startFrame: 0, levels: 1 });
    } else if (msg.event === "output") {
      log(s, (msg.body && msg.body.output) || "");
    } else if (msg.event === "terminated" || msg.event === "exited") {
      weft.status("○ " + s.buf + " · done");
      log(s, "\n□ program terminated\n", ST.muted);
      retire(s);
    }
    return;
  }
  if (msg.type === "response") {
    if (!msg.success) {
      log(s, "\n! " + msg.command + " failed: " + (msg.message || "") + "\n", ST.muted);
      return;
    }
    if (msg.command === "initialize") {
      // Capabilities in hand — launch the program (the `initialized` event that
      // follows drives breakpoints + configurationDone).
      send(s, "launch", { program: s.program, stopOnEntry: false });
    } else if (msg.command === "stackTrace") {
      const f = (msg.body && msg.body.stackFrames && msg.body.stackFrames[0]) || null;
      if (f) log(s, "  → " + ((f.source && f.source.name) || "?") + ":" + f.line + "  " + (f.name || "") + "\n", ST.location);
    }
    return;
  }
}

// Deframe Content-Length messages from ONE adapter's stdout. The stream handle
// names the session, so two adapters never share a frame accumulator.
weft.onOutput((h) => {
  const s = byHandle(h);
  if (!s) return;
  s.inbuf += weft.procRead(h);
  while (true) {
    const m = s.inbuf.match(/Content-Length: (\d+)\r?\n\r?\n/);
    if (!m) break;
    const len = parseInt(m[1], 10);
    const start = m.index + m[0].length;
    if (s.inbuf.length < start + len) break; // await the full body
    const body = s.inbuf.slice(start, start + len);
    s.inbuf = s.inbuf.slice(start + len);
    let msg;
    try {
      msg = JSON.parse(body);
    } catch (e) {
      continue;
    }
    onMessage(s, msg);
  }
});

// ── Commands ──────────────────────────────────────────────────────────
weft.command("debug-start", () => {
  const cmd = weft.config("cmd");
  if (!cmd) {
    weft.echo('debug: set an adapter — weft.set("dap","cmd","…")');
    return;
  }
  const buf = freeName();
  if (!buf) {
    weft.echo("debug: too many sessions");
    return;
  }
  const program = weft.config("program") || "program";
  const s = {
    buf,
    adapter: null,
    seq: 1,
    thread: 1,
    inbuf: "",
    program,
    source: weft.config("source") || program,
    line: parseInt(weft.config("line") || "1", 10),
  };
  sessions.push(s);
  recent = s;
  log(s, "debug: launching " + cmd + " → " + s.program + "\n", ST.muted);
  setStatus(s, "starting");
  s.adapter = weft.procSpawn(cmd);
  send(s, "initialize", {
    clientID: "weft",
    adapterID: "weft",
    linesStartAt1: true,
    columnsStartAt1: true,
    pathFormat: "path",
    supportsRunInTerminalRequest: false,
  });
  weft.echo("debug: started " + s.buf);
}, "start a debug session");

function stepCmd(name, command, summary) {
  weft.command(name, () => {
    const s = current();
    if (!s) {
      weft.echo("debug: no session — debug-start first");
      return;
    }
    send(s, command, { threadId: s.thread });
  }, summary);
}
stepCmd("debug-continue", "continue", "let the program run on");
stepCmd("debug-step-over", "next", "step over this line");
stepCmd("debug-step-into", "stepIn", "step into the call");
stepCmd("debug-step-out", "stepOut", "run to the end of this frame");

// Stop the FOCUSED session only — a second debugger keeps running.
weft.command("debug-stop", () => {
  const s = current();
  if (!s) {
    weft.echo("debug: no session");
    return;
  }
  // A session is retired by the adapter's `terminated`, not by asking: until
  // that arrives the stream is still ours, so its last words still land in its
  // own transcript instead of being dropped as an unowned frame.
  send(s, "disconnect", { terminateDebuggee: true });
  weft.status("○ " + s.buf + " · stopping");
  weft.echo("debug: stopping " + s.buf);
}, "stop the focused debug session");
