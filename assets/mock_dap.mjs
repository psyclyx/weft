// Mock Debug Adapter Protocol server — test fixture for weft's dap.js client.
// Speaks just enough DAP over Content-Length-framed stdio to exercise a full
// session: initialize (+ initialized event) → launch → setBreakpoints →
// configurationDone (→ stopped at a breakpoint) → stackTrace → continue
// (→ terminated). Bodies are ASCII, so char length == byte length here.

let sbuf = "";
let seq = 1;

function sendMsg(obj) {
  obj.seq = seq++;
  const body = JSON.stringify(obj);
  process.stdout.write("Content-Length: " + Buffer.byteLength(body) + "\r\n\r\n" + body);
}
function response(req, body) {
  sendMsg({ type: "response", request_seq: req.seq, command: req.command, success: true, body: body || {} });
}
function event(name, body) {
  sendMsg({ type: "event", event: name, body: body || {} });
}

function handle(req) {
  switch (req.command) {
    case "initialize":
      response(req, { supportsConfigurationDoneRequest: true });
      event("initialized");
      break;
    case "launch":
      response(req);
      break;
    case "setBreakpoints": {
      const bps = ((req.arguments && req.arguments.breakpoints) || []).map((b) => ({ verified: true, line: b.line }));
      response(req, { breakpoints: bps });
      break;
    }
    case "configurationDone":
      response(req);
      event("output", { category: "console", output: "program started\n" });
      event("stopped", { reason: "breakpoint", threadId: 1, allThreadsStopped: true });
      break;
    case "threads":
      response(req, { threads: [{ id: 1, name: "main" }] });
      break;
    case "stackTrace":
      response(req, {
        stackFrames: [{ id: 1, name: "main", line: 7, column: 1, source: { name: "program", path: "program" } }],
        totalFrames: 1,
      });
      break;
    case "continue":
      response(req, { allThreadsContinued: true });
      event("terminated");
      break;
    case "next":
    case "stepIn":
    case "stepOut":
      response(req);
      event("stopped", { reason: "step", threadId: 1 });
      break;
    case "disconnect":
      response(req);
      event("terminated");
      process.exit(0);
      break;
    default:
      response(req);
  }
}

process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  sbuf += chunk;
  while (true) {
    const m = sbuf.match(/Content-Length: (\d+)\r?\n\r?\n/);
    if (!m) break;
    const len = parseInt(m[1], 10);
    const start = m.index + m[0].length;
    if (sbuf.length < start + len) break;
    const body = sbuf.slice(start, start + len);
    sbuf = sbuf.slice(start + len);
    let req;
    try {
      req = JSON.parse(body);
    } catch (e) {
      continue;
    }
    if (req.type === "request") handle(req);
  }
});
