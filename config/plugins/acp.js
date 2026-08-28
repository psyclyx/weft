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
// CONVERSATIONS ARE INSTANCES. Every `agent-start` mints its OWN conversation:
// its own subprocess, its own ACP session, its own transcript buffer
// (`*agent*`, `*agent:2*`, … — the instanced tool-buffer naming idiom, the
// repl/console/llm and git RepoSessions precedent) and its own CRDT sub-peer
// (`claude#1`, `codex#2`), so selective undo separates one agent's edits from
// another's. Nothing here is keyed by "the current agent": streamed updates
// route by the proc handle that carried them, and a permission answer routes
// by the continuation token `weft.pick` hands back (conversation + tool-call
// id) — never by "the pending one".
//
// The transport (procSpawn/procSend/onOutput/procRead), the transcript
// (transcriptEntry/transcriptAppend) and the pick (pick/onPick) are the
// weft.* membrane; the protocol is plain JS over JSON.parse.

const BASE = "agent";
const MAX_CONVERSATIONS = 16;

// Live conversations, by ordinal. The ordinal is the instance identity: it
// names the transcript buffer and the CRDT sub-peer.
const convs = new Map();
// The conversation `agent-send` addresses (the most recently started, until
// `agent-focus` picks another).
let focused = null;

// `*agent*` at 1, `*agent:n*` above — the instanced tool-buffer naming idiom.
function instanceName(n) {
  return n <= 1 ? "*" + BASE + "*" : "*" + BASE + ":" + n + "*";
}

// The lowest ordinal no live conversation holds — what a new one takes.
function freeOrdinal() {
  for (let n = 1; n <= MAX_CONVERSATIONS; n++) if (!convs.has(n)) return n;
  return null;
}

function convByProc(h) {
  for (const c of convs.values()) if (c.proc === h) return c;
  return null;
}

function rpc(c, method, params) {
  const id = c.nextId++;
  weft.procSend(c.proc, JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  return id;
}

function respond(c, id, result) {
  weft.procSend(c.proc, JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
}

// The status-line chip — visible even when the transcript isn't focused.
function setStatus(c, dot, state) {
  weft.status(dot + " " + c.peer + " · " + state);
}

// ── The transcript: role-tagged entries, streamed, per conversation. ─────
//
// `liveKind` tracks which ROLE is currently open on this conversation's live
// entry — NOT which toolCallId or turn, a real simplification named here:
// consecutive chunks of the SAME role stream onto ONE entry; a role change
// opens a fresh one. `trOpen` is for a role that must ALWAYS start a new
// entry (a user prompt, a tool call header); `trAppend` opens on a role
// change and otherwise streams. The buffer name is the conversation's
// identity on the host side too: the host keeps one TranscriptDoc per
// projected buffer, so a chunk can only ever land in its own transcript.
function trOpen(c, role, text) {
  weft.transcriptEntry(c.buffer, role, text || "");
  c.liveKind = role;
}
function trAppend(c, role, text) {
  if (!text) return;
  if (c.liveKind !== role) trOpen(c, role, text);
  else weft.transcriptAppend(c.buffer, text);
}

// Send a prompt on an existing session (a subsequent turn) — its own
// transcript entry, always fresh (a user turn never merges into whatever
// role was open before it).
function sendPrompt(c, text) {
  // `c.proc === null`, never `!c.proc`: handle 0 is a perfectly good stream.
  if (c.proc === null || !c.sid || !text) return;
  trOpen(c, "user", text);
  setStatus(c, "●", "thinking");
  rpc(c, "session/prompt", { sessionId: c.sid, prompt: [{ type: "text", text: text }] });
}

// Render a tool_call_update's content (diffs, output) as plain text onto
// whatever entry `tool_call` just opened — DEFERRED: concurrent tool calls
// WITHIN one conversation (more than one toolCallId live at once) still
// collapse onto whichever entry is open. Cross-conversation interleaving is
// no longer a limitation: `c.buffer` decides the transcript.
//
// The old per-chunk `bufferFold`/`paintStyle` richness (role colors, folded tool
// output) is ALSO dropped here, but not lost for good — its return path is concrete,
// not a vague "later": `TranscriptDoc.fill`'s plain "role: text" projection is now
// the one and only content path (never a decoration a plugin paints over a
// SEPARATELY-driven raw append — that would resurrect exactly the parallel
// transcript representation the model exists to replace). Richness comes back as a
// DECORATION PROVIDER over THAT SAME projection's existing per-row subbuffer claims
// — the identical id-span mechanism `fill` already mints one of per entry
// (`node_fact`, carrying the entry's portable `NodeRef`) and dired's decoration
// renderer already consumes for its own rows
// (doc/contextual-workspace-architecture.md §11.8 — read a claim's facts, e.g. this
// entry's `role` looked up back through its `NodeRef`, and a tool entry's `kind`,
// and paint/fold purely from THAT, never from separately-tracked byte ranges a
// plugin keeps in sync by hand). Until that provider is built, the transcript reads
// as plain "role: text" rows — correct and honest, just undecorated.
function renderToolContent(c, u) {
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
  if (blob) weft.transcriptAppend(c.buffer, blob);
}

// ── Permission requests: one pending record per (conversation, tool call). ──
//
// `weft.pick` mutates head state (head-gated) and `onMessage` runs off
// `weft.onOutput` (BACKGROUND — no dispatching head), so opening the pick is
// deferred through a self-registered command: a nested `weft.run` IS a
// dispatching entry for its duration (the same door the wasm plugin plane
// uses for an on_poll-landed async result — see src/guest/lsp.zig). Only one
// pick can be open at a time, so the rest QUEUE; each carries its own token,
// so the order they open in never decides which request an answer resolves.
const pendingPerms = new Map(); // token -> {conv, rpcId, optionIds}
const pickQueue = []; // tokens waiting for the head
let pickOpen = false;

function permToken(c, callId) {
  return c.ordinal + "/" + callId;
}

function askPermission(c, msg) {
  const p = msg.params || {};
  const opts = p.options || [];
  if (!opts.length) {
    respond(c, msg.id, { outcome: { outcome: "cancelled" } });
    return;
  }
  const call = p.toolCall || {};
  const token = permToken(c, call.toolCallId || msg.id);
  pendingPerms.set(token, {
    conv: c,
    rpcId: msg.id,
    optionIds: opts.map((o) => o.optionId),
    prompt: c.peer + " · " + (call.title || call.toolCallId || "permission"),
    opts: opts.map((o) => o.name).join("\n"),
  });
  setStatus(c, "◌", "waiting");
  pickQueue.push(token);
  weft.run("acp-open-permission-pick");
}

// Open the next queued permission pick, if the head is free. Called from a
// dispatching entry only (the trampoline command, or `onPick`).
let openToken = null; // the token of the pick on screen, if any

function openNextPick() {
  if (pickOpen) return;
  while (pickQueue.length) {
    const token = pickQueue.shift();
    const p = pendingPerms.get(token);
    if (!p) continue; // withdrawn (its conversation ended)
    pickOpen = true;
    openToken = token;
    weft.pick(p.prompt, p.opts, token);
    return;
  }
}

// Internal: the deferred half of session/request_permission — not a
// user-facing verb, invoked only via weft.run from the background
// weft.onOutput handler.
weft.command("acp-open-permission-pick", openNextPick);

// The OTHER pick this plugin opens (`agent-focus`, below): its own
// continuation identity, and the conversations it offered.
const focus_token = "focus";
let focusChoices = [];

function acceptFocus(outcome) {
  const choices = focusChoices;
  focusChoices = [];
  if (outcome.kind !== "candidate" || outcome.index < 0 || outcome.index >= choices.length) return;
  focused = choices[outcome.index];
  weft.echo("acp: sending to " + focused.peer);
}

// A pick completed. The outcome carries the TOKEN the pick was opened with,
// so a permission answer resolves exactly one pending tool call — never "the
// pending one", which with two agents in flight would unblock the wrong
// conversation. Every pick this plugin opens has an identity here; an
// unknown token is ignored, never applied to whatever happens to be pending.
weft.onPick((outcome) => {
  if (!outcome) return;
  pickOpen = false;
  openToken = null;
  if (outcome.token === focus_token) {
    acceptFocus(outcome);
    openNextPick();
    return;
  }
  const p = pendingPerms.get(outcome.token);
  if (!p) {
    openNextPick();
    return;
  }
  pendingPerms.delete(outcome.token);
  if (outcome.kind !== "candidate" || outcome.index < 0 || outcome.index >= p.optionIds.length) {
    respond(p.conv, p.rpcId, { outcome: { outcome: "cancelled" } });
  } else {
    respond(p.conv, p.rpcId, {
      outcome: { outcome: "selected", optionId: p.optionIds[outcome.index] },
    });
  }
  setStatus(p.conv, "●", "thinking");
  openNextPick();
});

// One decoded JSON-RPC message from `c`'s agent.
function onMessage(c, msg) {
  // Streaming notifications (the turn's content).
  if (msg.method === "session/update") {
    const u = (msg.params && msg.params.update) || {};
    if (u.sessionUpdate === "agent_message_chunk" && u.content) {
      setStatus(c, "●", "streaming");
      trAppend(c, "agent", u.content.text || "");
    } else if (u.sessionUpdate === "agent_thought_chunk" && u.content) {
      trAppend(c, "thought", u.content.text || "");
    } else if (u.sessionUpdate === "tool_call") {
      trOpen(c, "tool", "[" + (u.kind || "tool") + "] " + (u.title || u.toolCallId || "") + "\n");
    } else if (u.sessionUpdate === "tool_call_update") {
      renderToolContent(c, u); // the verbose content, appended onto the open tool entry
    }
    return;
  }

  // Client-side requests the agent makes back into the editor.
  if (msg.method === "fs/read_text_file") {
    // Answer from the live buffer (or disk) — weft is the harness, so the agent
    // sees the honest current state, not stale bytes.
    respond(c, msg.id, { content: weft.fileRead((msg.params && msg.params.path) || "") });
    return;
  }
  if (msg.method === "fs/write_text_file") {
    // Apply as an attributed edit by THIS conversation's sub-peer (gated +
    // undoable) — not a raw disk write, and never confusable with another
    // agent's edits: selective undo separates claude#1 from codex#2.
    const p = msg.params || {};
    weft.fileWrite(p.path || "", p.content || "", c.peer);
    respond(c, msg.id, {});
    return;
  }
  if (msg.method === "session/request_permission") {
    askPermission(c, msg);
    return;
  }

  // A prompt result carries a stopReason → the turn finished.
  if (msg.result && msg.result.stopReason) {
    setStatus(c, "○", "idle");
    return;
  }
  // Responses to our own requests, keyed by this conversation's own id
  // counter (each session numbers its requests from zero).
  if (msg.id === 0 && msg.result) {
    rpc(c, "session/new", { cwd: ".", mcpServers: [] });
  } else if (msg.id === 1 && msg.result) {
    c.sid = msg.result.sessionId;
    sendPrompt(c, c.pending);
    c.pending = null;
  }
}

weft.onOutput((h) => {
  const c = convByProc(h);
  if (!c) return; // output from a stream no live conversation owns
  c.inbox += weft.procRead(h);
  let i;
  while ((i = c.inbox.indexOf("\n")) >= 0) {
    const line = c.inbox.slice(0, i);
    c.inbox = c.inbox.slice(i + 1);
    if (!line.trim()) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch (e) {
      continue; // ignore non-JSON (an adapter's stray stderr-on-stdout)
    }
    onMessage(c, msg);
  }
});

// ── An agent that exits ENDS its conversation ────────────────────────────
//
// The process IS the conversation's lifetime. When it goes, everything it
// left waiting is answered cancelled (agents.md's `session/cancel` outcome —
// no answer is written back to a dead pipe; the answer that exists is the
// local one), the transcript says so, and the ordinal returns to the pool.
// Nothing here is global: a pending record names its own conversation, so a
// second agent in flight keeps its queue, its pick and its slot.
let dead_pick = false; // the pick on screen belonged to a conversation that died

function endConversation(c, why) {
  for (const [token, p] of [...pendingPerms]) {
    if (p.conv !== c) continue;
    pendingPerms.delete(token); // queued tokens drop themselves in openNextPick
    if (openToken === token) dead_pick = true;
  }
  trOpen(c, "system", "agent exited (" + why + ")\n");
  setStatus(c, "○", "exited");
  convs.delete(c.ordinal);
  if (focused === c) focused = convs.values().next().value || null;
  weft.procClose(c.proc);
  c.proc = null;
  weft.run("acp-reap"); // the head-gated half; see below
}

// Internal: the deferred half of a conversation's end — closing the dead
// pick needs a dispatching head, and a nested `weft.run` is one. Cancelling
// resolves it through the ordinary `onPick` path, which then opens whatever
// a LIVE conversation still has queued.
weft.command("acp-reap", () => {
  if (!dead_pick) {
    openNextPick();
    return;
  }
  dead_pick = false;
  weft.run("pick-cancel");
});

weft.onExit((h) => {
  const c = convByProc(h);
  if (!c) return; // a stream no live conversation owns
  endConversation(c, "process exited");
});

// Start a conversation: mint its instance identity, spawn `cmd` (config data
// — the launch command), run the ACP handshake, and send `prompt` once the
// session exists. `name` names the agent (else config's `name`, else the
// command) — each conversation suffixes it with its own ordinal. Returns the
// conversation, or null when saturated. Exposed as a global so config / a
// command can kick it off.
function startAgent(cmd, prompt, name) {
  const ordinal = freeOrdinal();
  if (ordinal === null) {
    weft.echo("acp: too many conversations");
    return null;
  }
  // The identity this conversation's edits attribute to (a distinct CRDT
  // sub-peer): a configured name, else the launch command's first word,
  // suffixed with the instance ordinal. So "claude#1"/"codex#2" edits are
  // attributable + selectively-undoable per conversation.
  const base = name || weft.config("name") || cmd.split(/\s+/)[0].split("/").pop() || BASE;
  const c = {
    ordinal,
    buffer: instanceName(ordinal),
    peer: base + "#" + ordinal,
    proc: null,
    sid: null,
    nextId: 0,
    pending: prompt,
    inbox: "",
    liveKind: null,
  };
  convs.set(ordinal, c);
  focused = c;
  setStatus(c, "●", "starting");
  c.proc = weft.procSpawn(cmd);
  rpc(c, "initialize", {
    protocolVersion: 1,
    clientCapabilities: { fs: { readTextFile: true, writeTextFile: true } },
    clientInfo: { name: "weft", version: "0.1.0" },
  });
  return c;
}
globalThis.startAgent = startAgent;

// agent-start: launch a NEW conversation and run one turn. The launch command
// is config data (weft.set("acp", "cmd", "…") — never baked), and the opening
// prompt is weft.set("acp", "prompt", "…") (default "Hello").
weft.command("agent-start", () => {
  const cmd = weft.config("cmd");
  if (!cmd) {
    weft.echo('acp: set an agent command first — weft.set("acp","cmd","codex-acp")');
    return;
  }
  const c = startAgent(cmd, weft.config("prompt") || "Hello");
  if (c) weft.echo("acp: started " + cmd + " as " + c.peer + " → " + c.buffer);
});

// agent-send: send the current line as the next prompt of the FOCUSED
// conversation (a multi-turn turn). Type a request on any line and run this.
weft.command("agent-send", () => {
  const line = weft.lineText().trim();
  if (!line) {
    weft.echo("acp: nothing on this line to send");
    return;
  }
  if (!focused || !focused.sid) {
    weft.echo("acp: no session — run agent-start first");
    return;
  }
  sendPrompt(focused, line);
});

// agent-focus: choose which conversation `agent-send` addresses. It rides
// the same continuation token the permission picks use — a second identity
// sharing one `onPick`, which is the point: an outcome always says which
// request it answers, so this can never steal a permission answer (nor be
// answered by one).
weft.command("agent-focus", () => {
  if (!convs.size) {
    weft.echo("acp: no conversations");
    return;
  }
  if (pickOpen) {
    weft.echo("acp: answer the open request first");
    return;
  }
  pickOpen = true;
  focusChoices = [...convs.values()];
  weft.pick("agent conversation", focusChoices.map((c) => c.peer + " " + c.buffer).join("\n"), focus_token);
});
