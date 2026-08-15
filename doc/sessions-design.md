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
