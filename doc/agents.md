# weft — coding-agent support (ACP)

Agents are **plugins**, not core — the same rule as vim/git/lsp-policy. weft ships
no agent knowledge and no launch assumptions; a JS plugin drives the protocol and
the UI over the `weft.*` ABI, and agents are declared as config data.

## Decisions (settled)

- **ACP only.** One protocol — the Agent Client Protocol (Zed's; JSON-RPC 2.0,
  newline-delimited, over a subprocess's stdio). No raw `claude -p`. Claude is
  reached through its ACP adapter, like any other agent.
  - *Why:* under ACP the agent's file I/O and tool approvals are **callbacks into
    the editor** (`fs/read_text_file`, `fs/write_text_file`, `session/request_permission`),
    so **weft is the harness** — it gates every edit and applies it as an
    attributed agent-**peer** commit (selective-undo + attribution intact). A raw
    CLI harness (`claude -p`) edits the disk directly and weft could only observe;
    ACP is where the peer model pays off, so it's the only path.
- **Config-driven, zero baked assumptions** (NixOS-friendly). Agents are data,
  same shape as `lsp-add`/`grammar-add`:
  ```js
  weft.agent("claude", { protocol: "acp", cmd: ["/…/claude-agent-acp"] });
  weft.agent("codex",  { protocol: "acp", cmd: ["codex-acp"] });
  weft.agent("gemini", { protocol: "acp", cmd: ["gemini", "--experimental-acp"] });
  ```
  weft never guesses PATH / `npx`; you point at whatever your env provides.
- **JS plugin.** The adapter is JavaScript on quickjs (JSON.parse + an allocator
  make NDJSON/JSON-RPC tractable) — which requires making quickjs a first-class
  plugin host (today it is config-only). That build-out unlocks JS plugins
  generally, not just agents.
- **An agent is a peer; a conversation is a document.** Agent edits author as a
  named `role=.agent` sub-peer (`Document.spawnPeer`), autonomous (not
  `user_initiated`) → their own selective-undo unit, grade-capped at `.edit`. The
  transcript is a foldable model buffer (the magit/dired shape).

## ACP → weft mapping

| ACP (agent ⇄ editor) | weft |
|---|---|
| `initialize` / capability negotiation | plugin advertises `fs.{read,write}`, `terminal` |
| `session/new { cwd }` | spawn in the **project root** (cwd primitive) |
| `session/prompt` | prompt input in the conversation buffer |
| `session/update` (message/thought/tool_call/plan chunks) | streamed into the transcript model buffer (fold/style) |
| `session/request_permission` | the **pick membrane** (async approve/deny — already exists) |
| `fs/read_text_file` | read the buffer's live CRDT text (honest, not stale disk) |
| `fs/write_text_file` / tool_call `diff` | a **named agent-peer edit** through `Context.edit` (gated, attributed, undoable) |
| `terminal/*` | the `proc` capability (spawn with cwd) |
| `session/cancel` | cancel the turn; answer any pending permission with `cancelled` |
| usage (agent-reported) | status chip + dashboard; subscription % later |

## Generic primitives to add (agent-agnostic — each useful on its own)

The hard mechanics already exist (persistent duplex subprocess `repl_session`,
`Document.spawnPeer` for named agent peers, fold/style/surface, kv, the pick
membrane for async approve/deny). The gaps:

1. **Spawn `cwd`** on proc/session — run a child in a chosen dir. Also fixes
   grep/run/git scoping. (Core: `proc.Options.cwd`; surfaced to the guest.)
2. **`fs.exists` / `fs.stat`** — for clean project-root detection (today only
   `fs.list` + name-scan). 
3. **Named-agent authorship from a guest** (`author_as(name)`) — core supports it
   (`spawnPeer`/`peerNamed`, `Context.edit` peer branch); only the ABI is missing.
4. **`weft.agent(...)` config registry** — declare agents as data.
5. **A status-line segment primitive** — the status line is core-owned; give a
   plugin a persistent chip (the "● claude waiting" indicator + usage). Generic
   status feed.
6. **JS as a first-class plugin host** — quickjs as a reactor exposing the guest
   export set + the full `weft.*` membrane into JS (today: config-only, 5 imports).
7. **Stream-to-guest** — a live subprocess's stdout must reach the guest to be
   parsed (today it lands only in a buffer, and there is no per-frame guest hook).
   An `on_output(handle, chunk)` fired at the frame boundary (never nested in a
   guest call — the wasm-store re-entrancy rule).
8. *(refinement)* **project** plugin: walk up to the dominating `.git`/marker,
   track a current project, publish `project-root` / `project-switch` as
   late-bound names the agent plugin (cwd), grep, and run consume.

Permission UI needs **no** new primitive — the pick membrane already does async
approve/deny (a two-item pick), which also gives dired-reconcile its confirmation.

## UI types (all plugin-drawn; mockups in the design thread)

1. **Conversation buffer** — foldable transcript + inline tool-calls/diffs + a
   prompt input, its own `agent` keymap mode (`RET` send, `TAB` fold, `c` cancel,
   `f` fork, `y/a/n` permission, `q` close). A real buffer → splits/search work.
2. **Sessions dashboard** (`*agents*`) — magit-style, grouped by agent/status,
   with fork/delete; plus a picker for quick-switch.
3. **Status segment** — a global "● claude waiting" chip (visible when the
   conversation is unfocused) + usage.

## Status (what's built)

The ACP client works end-to-end and is launchable in the running editor:

- **Phase 0 primitives** — all in: proc spawn `cwd`; `fs.exists`; `project-root`
  detection; `edit_as` (named agent sub-peer authorship, with `Context.edit`
  refined so an `.agent` never joins the user's undo).
- **Phase 1 — JS plugin host** — done: `quickjs.wasm` is a first-class plugin
  (persistent reactor: `weft_plugin_init` + `weft_on_command`, `weft.command`
  via `qjs_register`); `JsPlugin` shares the config membrane + registers
  trampoline commands. `.js` plugins load via `weft.plugin("acp.js")` and are
  ticked each frame.
- **Phase 2 — stream-to-guest** — done: `core/proc_stream` (a duplex child the
  guest reads) + the JS membrane `weft.procSpawn/procSend/procRead` +
  `weft.onOutput` (fired at the frame boundary), and `weft.bufferAppend` /
  `weft.config` for the transcript + config-driven launch.
- **Phase 3 — the ACP client** — `config/plugins/acp.js`: JSON-RPC over stdio,
  the initialize → session/new → session/prompt handshake, `session/update`
  parsing → transcript, and the harness callbacks: **`fs/read_text_file`** →
  `weft.fileRead` (the live buffer, else disk — the agent sees your code) and
  **`fs/write_text_file`** → `weft.fileWrite` (a gated, attributed, undoable
  **agent-peer** edit — the harness payoff). Verified end-to-end against a mock
  ACP agent (no agent binary or display needed). **A working coding agent:**
  reads + writes your files + streams responses. Launchable: `weft.set("acp",
  "cmd",…)` + `weft.plugin("acp.js")` + `agent-start`.

**Remaining (refinements on the working agent):**
- A prompt INPUT per turn (the command-arg or text-input membrane into JS) —
  today the opening prompt is config data (one turn).
- `session/request_permission` → the pick membrane (currently default-deny,
  which is safe — it gates non-fs tool calls like shell exec).
- Per-conversation agent identity (fs writes author as a single `agent` peer
  for now) and usage tracking.
- UI polish: transcript folding/styling, the status-line "● agent" segment, the
  sessions dashboard.

## Build order (each phase committable, independently useful)

- **Phase 0 — generic primitives:** spawn `cwd`; `fs.exists`/`stat`; named-agent
  authorship (`author_as`); `weft.agent` registry; status-line segment; the
  `project` root-detection upgrade.
- **Phase 1 — JS plugin host:** quickjs reactor + full `weft.*` membrane into JS.
  The long pole.
- **Phase 2 — stream-to-guest:** `on_output` / stream-read at the frame boundary.
- **Phase 3 — the agent plugin (JS):** session model + transcript buffer + prompt
  + permission (pick) + usage; then the dashboard + status chip. Forking uses
  ACP `session/load` + replay (no native fork in ACP).

## Notes / uncertainties

- ACP framing is newline-delimited JSON (SDK `Lines` transport; one JSON object or
  one batch array per line) — not Content-Length. Verify against the live adapter.
- ACP adapter package names churn (`@zed-industries/claude-code-acp` →
  `@agentclientprotocol/claude-agent-acp`); since commands are config, that's the
  user's concern, not weft's.
- Usage is not standardized across ACP agents; start with whatever an agent
  reports, subscription-% (CLI `/usage`, rate-limit headers) later.
