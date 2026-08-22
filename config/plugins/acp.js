// acp.js — an ACP (Agent Client Protocol) client, as a weft JS plugin.
//
// Speaks JSON-RPC 2.0 over an agent subprocess's stdio (newline-delimited),
// drives the initialize → session/new → session/prompt handshake, and feeds
// the agent's streamed messages into a LIVE `TranscriptDoc` (the W6 check-in
// model, core/transcript.zig) via `weft.transcriptEntry`/`transcriptAppend` —
// the host owns the model + its graph-doc replication; this plugin only ever
// says WHAT a chunk is (role, text), never how it's stored. weft is the
// harness: the agent's file I/O and tool approvals arrive as callbacks the
// editor answers (fs/read, fs/write, request_permission), so every agent edit
// is a gated, attributed peer commit. Agents are config data — the command to
// launch is passed in, not baked (NixOS-friendly); nothing here assumes how
// the adapter is installed.
//
// State is per-session; this first cut drives ONE session (the
// single-instance limitation `transcript.zig`'s `SaveBinding` and
// `JsPlugin.transcript` both document — a per-buffer transcript registry is a
// named, un-built deferral, not multiplexed here). The transport
// (procSpawn/procSend/onOutput/procRead) and the transcript
// (transcriptEntry/transcriptAppend) are the weft.* membrane; the protocol is
// plain JS over JSON.parse.

const TRANSCRIPT = "*agent*";

let agent = null; // the proc-stream handle for the running agent
let sid = null; // the ACP session id, once session/new returns
let nextId = 0; // JSON-RPC request id counter
let pending = null; // the prompt to send once the session exists
let buf = ""; // partial-line accumulator for the NDJSON stream
let pendingPerm = null; // an outstanding session/request_permission: {id, optionIds}
let pendingPermPick = null; // {prompt, opts} for the deferred weft.pick — see onMessage
let agentName = "agent"; // the CRDT peer this agent's edits attribute to

function rpc(method, params) {
  const id = nextId++;
  weft.procSend(agent, JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  return id;
}

function respond(id, result) {
  weft.procSend(agent, JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
}

// The status-line chip — visible even when the transcript isn't focused.
function setStatus(dot, state) {
  weft.status(dot + " " + agentName + " · " + state);
}

// ── The transcript: role-tagged entries, streamed. ──────────────────────
//
// `liveKind` tracks which ROLE is currently open on the host's single live
// entry (JsPlugin.transcript_live_text) — NOT which toolCallId or turn, a
// real simplification named here: consecutive chunks of the SAME role
// (agent_message_chunk after agent_message_chunk, say) stream onto ONE
// entry; a role change opens a fresh one. `trOpen` is for a role that must
// ALWAYS start a new entry regardless of what's currently open (a user
// prompt, a tool call header); `trAppend` opens on a role change and
// otherwise streams.
let liveKind = null;

function trOpen(role, text) {
  weft.transcriptEntry(TRANSCRIPT, role, text || "");
  liveKind = role;
}
function trAppend(role, text) {
  if (!text) return;
  if (liveKind !== role) trOpen(role, text);
  else weft.transcriptAppend(TRANSCRIPT, text);
}

// Send a prompt on the existing session (a subsequent turn) — its own
// transcript entry, always fresh (a user turn never merges into whatever
// role was open before it).
function sendPrompt(text) {
  if (!agent || !sid || !text) return;
  trOpen("user", text);
  setStatus("●", "thinking");
  rpc("session/prompt", { sessionId: sid, prompt: [{ type: "text", text: text }] });
}

// Render a tool_call_update's content (diffs, output) as plain text onto
// whatever entry `tool_call` just opened — DEFERRED: concurrent/interleaved
// tool calls (more than one toolCallId live at once) collapse onto whichever
// entry happens to be open, matching the flat-stream behavior this replaces
// rather than a new limitation.
//
// The old per-chunk `bufferFold`/`paintStyle` richness (role colors, folded
// tool output) is ALSO dropped here, but not lost for good — its return
// path is concrete, not a vague "later": `TranscriptDoc.fill`'s plain
// "role: text" projection is now the one and only content path (never a
// decoration a plugin paints over a SEPARATELY-driven raw append — that
// would resurrect exactly the parallel transcript representation the model
// exists to replace). Richness comes back as a DECORATION PROVIDER over
// THAT SAME projection's existing per-row subbuffer claims — the identical
// id-span mechanism `fill` already mints one of per entry (`node_fact`,
// carrying the entry's portable `NodeRef`) and dired's decoration renderer
// already consumes for its own rows (editable-projection Phase 2,
// doc/editable-projection.md: "the decoration renderer" — read a claim's
// facts, e.g. this entry's `role` looked up back through its `NodeRef`, and
// a tool entry's `kind`, and paint/fold purely from THAT, never from
// separately-tracked byte ranges a plugin keeps in sync by hand). Until
// that provider is built, the transcript reads as plain "role: text" rows —
// correct and honest, just undecorated.
function renderToolContent(u) {
  const items = u.content || [];
  if (!items.length) return;
  let blob = "";
  for (const it of items) {
    if (it.type === "diff") {
      blob += "    " + (it.path || "") + "\n";
      if (it.oldText) blob += it.oldText.split("\n").map((l) => "    - " + l).join("\n") + "\n";
      if (it.newText) blob += it.newText.split("\n").map((l) => "    + " + l).join("\n") + "\n";
    } else if (it.type === "content" && it.content) {
      blob += "    " + (it.content.text || "") + "\n";
    }
  }
  if (blob) weft.transcriptAppend(TRANSCRIPT, blob);
}

// One decoded JSON-RPC message from the agent.
function onMessage(msg) {
  // Streaming notifications (the turn's content).
  if (msg.method === "session/update") {
    const u = (msg.params && msg.params.update) || {};
    if (u.sessionUpdate === "agent_message_chunk" && u.content) {
      setStatus("●", "streaming");
      trAppend("agent", u.content.text || "");
    } else if (u.sessionUpdate === "agent_thought_chunk" && u.content) {
      trAppend("thought", u.content.text || "");
    } else if (u.sessionUpdate === "tool_call") {
      trOpen("tool", "[" + (u.kind || "tool") + "] " + (u.title || u.toolCallId || "") + "\n");
    } else if (u.sessionUpdate === "tool_call_update") {
      renderToolContent(u); // the verbose content, appended onto the open tool entry
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
    // weft.pick MUTATES head state (task #19 item 4 — head-gated) and
    // onMessage runs off weft.onOutput (BACKGROUND — no dispatching head).
    // Defer through a self-registered command below: a nested weft.run IS a
    // dispatching entry for its duration (same door the wasm plugin plane
    // uses for an on_poll-landed async result — see src/guest/lsp.zig).
    pendingPermPick = { prompt: "agent · " + title, opts: opts.map((o) => o.name).join("\n") };
    weft.run("acp-open-permission-pick");
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

// Internal: the deferred half of session/request_permission (see onMessage)
// — not a user-facing verb, invoked only via weft.run from the background
// weft.onOutput handler. weft.pick needs a dispatching entry; this command
// IS one.
weft.command("acp-open-permission-pick", () => {
  if (!pendingPermPick) return;
  const pp = pendingPermPick;
  pendingPermPick = null;
  weft.pick(pp.prompt, pp.opts);
});

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
// CONTINUITY ACROSS RESTARTS (undocumented before this pass, worth stating
// plainly): the live `TranscriptDoc` lives on the HOST's `JsPlugin`
// instance, not in this JS module's state — calling `startAgent` again
// (a re-launch, or a config-driven restart of the same running plugin)
// does NOT start a fresh transcript. It CONTINUES appending new entries
// onto the SAME model `weft.transcriptEntry` first created, so a second
// agent's turns land after the first agent's, in the SAME buffer, as more
// rows of one growing conversation — not two separate sessions. Whether
// that's the right default for a genuine agent SWAP (a different `cmd`) vs.
// a mere reconnect of the SAME agent is an open UX question this slice
// doesn't answer; `liveKind = null` below only resets which ROLE is
// considered "live" for streaming purposes (so the next chunk always opens
// a fresh row rather than accidentally appending onto whatever the PRIOR
// agent's session left open) — it does NOT start a new transcript.
//
// EAGER BUFFER CREATION, DROPPED: earlier versions of this file called
// `transcript("")` here to make the `*agent*` buffer exist immediately (so
// e.g. a split could show it before any content arrived). That called
// `weft.bufferAppend` directly, which is gone — an empty `weft.
// transcriptEntry` call would mint a spurious empty ROW in the model
// (there is no "just create the buffer" verb that isn't also "create an
// entry" for a graph-backed model), so this was deliberately NOT
// preserved. The buffer now appears lazily, on the FIRST real entry
// (`sendPrompt`'s `trOpen("user", prompt)`, just below) — a small,
// intentional timing difference from before.
function startAgent(cmd, prompt) {
  // The identity this agent's edits attribute to (a distinct CRDT peer): a
  // configured name, else the launch command's first word. So "claude"/"codex"
  // edits are attributable + selectively-undoable per agent.
  agentName = weft.config("name") || cmd.split(/\s+/)[0].split("/").pop() || "agent";
  pending = prompt;
  setStatus("●", "starting");
  liveKind = null; // the next chunk always opens a fresh row (see module note above) — never resets the transcript itself
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
