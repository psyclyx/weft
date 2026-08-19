// acp.js — an ACP (Agent Client Protocol) client, as a weft JS plugin.
//
// Speaks JSON-RPC 2.0 over an agent subprocess's stdio (newline-delimited),
// drives the initialize → session/new → session/prompt handshake, and renders
// the agent's streamed messages into a transcript buffer. weft is the harness:
// the agent's file I/O and tool approvals arrive as callbacks the editor
// answers (fs/read, fs/write, request_permission — a later pass wires these to
// weft.editAs + the pick membrane), so every agent edit is a gated, attributed
// peer commit. Agents are config data — the command to launch is passed in, not
// baked (NixOS-friendly); nothing here assumes how the adapter is installed.
//
// State is per-session; this first cut drives ONE session. The transport
// (procSpawn/procSend/onOutput/procRead) and the transcript (bufferAppend) are
// the weft.* membrane; the protocol is plain JS over JSON.parse.

const TRANSCRIPT = "*agent*";

let agent = null; // the proc-stream handle for the running agent
let sid = null; // the ACP session id, once session/new returns
let nextId = 0; // JSON-RPC request id counter
let pending = null; // the prompt to send once the session exists
let buf = ""; // partial-line accumulator for the NDJSON stream
let pendingPerm = null; // an outstanding session/request_permission: {id, optionIds}
let agentName = "agent"; // the CRDT peer this agent's edits attribute to

function rpc(method, params) {
  const id = nextId++;
  weft.procSend(agent, JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  return id;
}

function respond(id, result) {
  weft.procSend(agent, JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
}

// StyleClass values (core.capability.StyleClass), painted over the appended
// range so the transcript reads by role: prompts, thoughts, tool calls.
const ST = { normal: 0, location: 4, emphasis: 5, muted: 6 };

function transcript(text, cls) {
  weft.bufferAppend(TRANSCRIPT, text, cls || 0);
}

// The status-line chip — visible even when the transcript isn't focused.
function setStatus(dot, state) {
  weft.status(dot + " " + agentName + " · " + state);
}

// Send a prompt on the existing session (a subsequent turn). Renders the prompt
// into the transcript so the conversation reads as a whole.
function sendPrompt(text) {
  if (!agent || !sid || !text) return;
  transcript("\n\n› " + text + "\n", ST.emphasis);
  setStatus("●", "thinking");
  rpc("session/prompt", { sessionId: sid, prompt: [{ type: "text", text: text }] });
}

// Usage/cost, wherever an agent puts it (ACP doesn't standardize it) — parsed
// defensively and rendered dimmed into the transcript.
function usageOf(msg) {
  return (
    (msg.params && msg.params.update && msg.params.update.usage) ||
    (msg.result && msg.result.usage) ||
    msg.usage ||
    null
  );
}
function showUsage(u) {
  const inTok = u.input_tokens ?? u.inputTokens ?? u.prompt_tokens;
  const outTok = u.output_tokens ?? u.outputTokens ?? u.completion_tokens;
  const cost = u.total_cost_usd ?? u.cost ?? u.costUSD;
  let s = "· usage";
  if (inTok != null) s += " ↑" + inTok;
  if (outTok != null) s += " ↓" + outTok;
  if (cost != null) s += " $" + (typeof cost === "number" ? cost.toFixed(4) : cost);
  if (s !== "· usage") transcript("\n" + s + "\n", ST.muted);
}

// Render a tool_call_update's content (diffs, output) then FOLD it, so the
// verbose bits collapse under the tool header. Byte offsets come from the host
// (weft.bufferLen) so folds are correct under multibyte text.
function prefixLines(s, p) {
  return (
    s
      .split("\n")
      .map((l) => "    " + p + l)
      .join("\n") + "\n"
  );
}
function renderToolContent(u) {
  const items = u.content || [];
  if (!items.length) return;
  const start = weft.bufferLen(TRANSCRIPT);
  for (const it of items) {
    if (it.type === "diff") {
      transcript("    " + (it.path || "") + "\n", ST.muted);
      if (it.oldText) transcript(prefixLines(it.oldText, "- "), ST.muted);
      if (it.newText) transcript(prefixLines(it.newText, "+ "), ST.muted);
    } else if (it.type === "content" && it.content) {
      transcript("    " + (it.content.text || "") + "\n", ST.muted);
    }
  }
  const end = weft.bufferLen(TRANSCRIPT);
  if (end > start) weft.bufferFold(TRANSCRIPT, start, end);
}

// One decoded JSON-RPC message from the agent.
function onMessage(msg) {
  const u = usageOf(msg);
  if (u) showUsage(u);
  // Streaming notifications (the turn's content).
  if (msg.method === "session/update") {
    const u = (msg.params && msg.params.update) || {};
    if (u.sessionUpdate === "agent_message_chunk" && u.content) {
      setStatus("●", "streaming");
      transcript(u.content.text || "");
    } else if (u.sessionUpdate === "agent_thought_chunk" && u.content) {
      transcript(u.content.text || "", ST.muted); // thoughts, dimmed
    } else if (u.sessionUpdate === "tool_call") {
      transcript("\n[" + (u.kind || "tool") + "] " + (u.title || u.toolCallId || "") + "\n", ST.location);
    } else if (u.sessionUpdate === "tool_call_update") {
      renderToolContent(u); // the verbose content, folded under the header
    }
    return;
  }

  // Client-side requests the agent makes back into the editor. Minimal, honest
  // answers for now; fs/write → weft.editAs and request_permission → the pick
  // membrane land in the next pass.
  if (msg.method === "fs/read_text_file") {
    // Answer from the live buffer (or disk) — weft is the harness, so the agent
    // sees the honest current state, not stale bytes.
    respond(msg.id, { content: weft.fileRead((msg.params && msg.params.path) || "") });
    return;
  }
  if (msg.method === "fs/write_text_file") {
    // Apply as an attributed agent-peer edit (gated + undoable) — not a raw
    // disk write. weft is the harness.
    const p = msg.params || {};
    weft.fileWrite(p.path || "", p.content || "", agentName);
    respond(msg.id, {});
    return;
  }
  if (msg.method === "session/request_permission") {
    const p = msg.params || {};
    const opts = p.options || [];
    if (!opts.length) {
      respond(msg.id, { outcome: { outcome: "cancelled" } });
      return;
    }
    // Ask the user (a pick); the choice comes back via weft.onPick below.
    pendingPerm = { id: msg.id, optionIds: opts.map((o) => o.optionId) };
    const title = (p.toolCall && (p.toolCall.title || p.toolCall.toolCallId)) || "permission";
    setStatus("◌", "waiting");
    weft.pick("agent · " + title, opts.map((o) => o.name).join("\n"));
    return;
  }

  // A prompt result carries a stopReason → the turn finished.
  if (msg.result && msg.result.stopReason) {
    setStatus("○", "idle");
    return;
  }
  // Responses to our own requests, keyed by the sequential id.
  if (msg.id === 0 && msg.result) {
    rpc("session/new", { cwd: ".", mcpServers: [] });
  } else if (msg.id === 1 && msg.result) {
    sid = msg.result.sessionId;
    sendPrompt(pending);
  }
}

// A permission pick was accepted: answer the agent with the chosen option (or
// cancelled for an out-of-range / dismissed choice).
weft.onPick((index) => {
  if (!pendingPerm) return;
  const p = pendingPerm;
  pendingPerm = null;
  if (index < 0 || index >= p.optionIds.length) {
    respond(p.id, { outcome: { outcome: "cancelled" } });
  } else {
    respond(p.id, { outcome: { outcome: "selected", optionId: p.optionIds[index] } });
  }
});

weft.onOutput((h) => {
  buf += weft.procRead(h);
  let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i);
    buf = buf.slice(i + 1);
    if (!line.trim()) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch (e) {
      continue; // ignore non-JSON (an adapter's stray stderr-on-stdout)
    }
    onMessage(msg);
  }
});

// Start an agent session: spawn `cmd` (from config — the launch command), run
// the ACP handshake, and send `prompt` once the session exists. Exposed as a
// global so config / a command can kick it off; command-arg + config-read
// wiring (so the prompt comes from an input line and `cmd` from weft.agent) is
// the remaining integration.
function startAgent(cmd, prompt) {
  // The identity this agent's edits attribute to (a distinct CRDT peer): a
  // configured name, else the launch command's first word. So "claude"/"codex"
  // edits are attributable + selectively-undoable per agent.
  agentName = weft.config("name") || cmd.split(/\s+/)[0].split("/").pop() || "agent";
  pending = prompt;
  setStatus("●", "starting");
  transcript(""); // ensure the transcript buffer exists
  agent = weft.procSpawn(cmd);
  rpc("initialize", {
    protocolVersion: 1,
    clientCapabilities: { fs: { readTextFile: true, writeTextFile: true } },
    clientInfo: { name: "weft", version: "0.1.0" },
  });
}
globalThis.startAgent = startAgent;

// agent-start: launch the configured agent and run one turn. The launch
// command is config data (weft.set("acp", "cmd", "…") — never baked), and the
// opening prompt is weft.set("acp", "prompt", "…") (default "Hello"). A prompt
// INPUT (type your own each turn) needs the command-arg / text-input membrane
// and lands next; this proves the live round-trip against a real agent.
weft.command("agent-start", () => {
  const cmd = weft.config("cmd");
  if (!cmd) {
    weft.echo('acp: set an agent command first — weft.set("acp","cmd","codex-acp")');
    return;
  }
  startAgent(cmd, weft.config("prompt") || "Hello");
  weft.echo("acp: started " + cmd);
});

// agent-send: send the current line as the next prompt (a multi-turn
// conversation). Type a request on any line and run this (bind a key) — it
// reuses the running session.
weft.command("agent-send", () => {
  const line = weft.lineText().trim();
  if (!line) {
    weft.echo("acp: nothing on this line to send");
    return;
  }
  if (!sid) {
    weft.echo("acp: no session — run agent-start first");
    return;
  }
  sendPrompt(line);
});
