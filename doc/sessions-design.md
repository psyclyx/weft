# Phase 3 design: multi-buffer, multi-session, remote-first files

Direction set 2026-08-15 (user): stemma changes approved (run-RLE +
hole-bases); tramp-class remote files are a first-class requirement,
not a multiplayer side effect; multiple concurrent sessions; files can
be pulled into sessions; saves can target other hosts.

## Model

**Session** = a routing fabric: an authenticated link-set to a set of
peers, carrying any number of documents. Not an ownership domain.

**Document** = one CRDT history, identified by its history root — not
by path. Paths are per-host names for it. Exactly one **home host** per
document: the peer responsible for persistence (its fs holds the file;
plain save lands there). Hosting is per-document, not per-session.

**The local editor is itself a session** with the local host (the
`host.fs` peer that already exists). Remote-first falls out: a remote
file is a document homed on an agent where you are the only peer;
adding a coworker to the same document changes nothing structurally.

**Buffers**: the editor holds N buffers (today's Editor struct becomes
per-buffer; the singletons in main — syntax, lsp binding, collab
binding — move inside it). A buffer binds one document + one session.
The buffer list is the union across sessions; `buffers` is a pick.

## The cases

1. **Shared checkout multiplayer**: session directory (control-class
   messages) maps wire channels ↔ documents: announce {channel, name,
   host, root-id}, open-by-name. Op/feed/blob frames already carry a
   channel; Collab becomes per-(session, document).

2. **Divergent checkouts**: a shared document has ONE history root;
   joining a document whose local file differs = adopt the shared root
   and import your local difference as your ops (diff local bytes vs
   the shared text → replacements → your commits), or decline into a
   private buffer. Never merge unrelated histories; never guess by
   content equality.

3. **Multiple sessions**: sessions are values; buffers reference them.
   Private-by-default: opening a file outside a shared session lands in
   the local session. Presence/feeds are per-session per-document.

4. **Pull a file into a session** = publish to the directory. Either
   the puller stays home host (peers replicate from the editor) or the
   session's agent adopts the history and becomes home (persistence
   moves). Explicit, one command: `share` / `share-to-agent`.

5. **Save routing**: the filesystem becomes a capability family —
   fs/read, fs/write, fs/list — one provider per peer (placement =
   that peer). `save` = fs/write at the document's home host (status
   quo). `save-to` = same request, chosen (peer, path). fs/list gives
   remote directory browsing (pick over entries) — the tramp story —
   with zero new transport machinery (request class).

## Stemma work (approved)

- **run-RLE event encoding**: typing bursts as runs in the wire batch
  section (doc/stemma-rle-proposal.md) — shrinks live traffic and
  offline resync payloads.
- **hole-bearing bases**: TextDoc bases with reserved-id unrealized
  ranges (doc/stemma-holes-proposal.md) — upgrades the read-only
  partial-checkout viewer into an editable document; base realization
  is not an edit; ops at hole boundaries legal.

## Build order (each proves the previous)

1. stemma: run-RLE (wire win, no editor changes) then hole-bases.
2. Multi-document sessions: directory protocol + per-doc channels +
   Collab-per-doc; agent hosts a worktree (N files), fs/list + open-by
   -name (tramp usable here).
3. Editor multi-buffer: Editor-per-buffer, buffer list/switch pick,
   per-buffer syntax/lsp/collab bindings.
4. fs capability family + save-to + share/publish + divergent-checkout
   adoption flow.

## Revision: no agent assumed (2026-08-15)

Constraint from review: remote editing must work on a box with only a
shell and coreutils — no agent binary pushable.

**Split "home host" into two independent bindings:**
- **Storage target** = (fs provider, path): where saves land. An fs
  provider need not be a wire peer. The bottom-tier provider is a
  **remote-shell fs**: it drives one persistent remote shell (spawned
  by any command — ssh is the default spawner, not a dependency: adb,
  serial, container exec all fit) and implements fs/read via dd+base64
  (ranged — partial checkout works, slowly), fs/write via base64 -d >
  tmp && mv (atomic), fs/list via ls -la parsing, size via wc -c.
  This is tramp's mechanism as a first-class provider.
- **Collaboration topology** = which peers replicate the CRDT. A
  dumb-host file is homed in the opener's editor; multiplayer on it
  still works (editor↔editor session) with storage routed to the shell
  provider — collaboration and storage are orthogonal.

**Host capability ladder** (auto-detected at open, surfaced in the
status line): shell+coreutils → scion-agent. The agent adds: a
persistent CRDT peer (document outlives your session), host-placement
compute (LSP where the code lives), efficient blob serving, and hub
multiplayer. Everything above the fs family degrades gracefully when
absent — LSP falls back to a local server over the shell fs (correct
for single-file; project-aware needs the agent) or to tree-sitter
only.

Build-order insert: the remote-shell fs provider lands WITH the fs
capability family (step 5 → becomes step 3.5, before or alongside the
agent worktree work), so the tramp story never depends on agent
availability.

## Revision 2: editor-shaped, no dedicated agent (2026-08-15)

Review: the session/directory/hosting-tier formalism was agent-centric
and un-editor-like. Simplified model, superseding the above where they
conflict:

- **Buffers have backings.** A backing = where the bytes live: a local
  path, or a remote path over a shell (coreutils tier). `save` writes
  the backing; `save-as` re-points it. No "storage targets", no
  "home hosts" — just backings.
- **Editors connect to editors.** A buffer may be **shared** over a
  connection: the peer sees it in their buffer list and opens it;
  edits converge (one history root per shared buffer; a joiner whose
  local file diverges imports the diff as their ops or opens private).
  Implementation: a per-connection shared-buffer list, per-buffer wire
  channels — no session directory abstraction.
- **No dedicated agent.** scion IS the peer. A persistent/headless
  host = `scion --headless --listen` (window optional; same binary).
  Fold scion-agent into that and delete the separate target; its one
  real advantage (loading without wayland/vulkan userspace) applies
  only to boxes that get the coreutils tier anyway. Host-placed LSP =
  "the LSP runs in whichever editor shares the buffer from its
  checkout" — which is just the M3 provider registered in that
  process, no placement machinery beyond what exists.

Kept from earlier revisions: the peer model, wire v1, the shell-fs
tier (ssh as default spawner, not a coupling), one-history-root
sharing, stemma RLE + hole-bases (approved). Build order becomes:
stemma work → shell-fs backings → multi-buffer editor (buffers +
backings + share) → --headless, delete scion-agent.

**Addendum (merged from a duplicated revision):** for a solo remote
file (no sharing editor on that box), host-run LSP still needs no
deployment — the LSP child process can be `ssh box zls`: our adapter
already speaks child stdio, so the server runs where the code lives
with zero installed bytes. That covers project-aware analysis on
coreutils-tier boxes that happen to have a language server.

## Revision 3: tool buffers (magit-class) (2026-08-15)

Everything is a Document; the differences are bindings, not kinds:

- **Backing = authority, not path**: file | shell-remote file | tool |
  none (scratch). A tool backing regenerates content by being a plugin
  PEER (replica commits — refresh merges like any concurrent editor;
  no special refresh machinery). No save unless the tool defines one.
- **Interaction = keymap mode**: a magit buffer sets mode "magit"
  (bindings → commands, text swallowed) — the vim-normal mechanism
  reused. read_only flag as belt-and-braces.
- **Structure = a layer**: the generator publishes sections (hunks,
  files, entries) as anchored spans with tool-defined kinds; commands
  resolve the cursor against the section layer. Faces likewise.
- **Sharing falls out**: tool buffers are documents; sharing one
  (pair-driving a rebase) is the tool's policy call, not the core's.

Dired/compilation/grep/REPL = same recipe, different tool. Additions
to the multi-buffer milestone: backing as the four-case interface;
buffer-local mode save/restore on focus switch; plugin API
scion.buffer-create + scion.layer-publish (+ section lookup helper)
so tool buffers are writable in fennel.
