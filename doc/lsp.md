# LSP as a plugin

## The principle

LSP is JSON-RPC over stdio with `Content-Length` framing — the *same shape* as
DAP (`dap.js`) and ACP (`acp.js`), which are already JS plugins. So the natural
home for LSP in weft is a **JS plugin, `lsp.js`**, not core. Core keeps only the
generic primitives a plugin can't synthesize (talk to a subprocess, read the
document, move the cursor, edit through the gated door, decorate the buffer,
open a pick). Everything LSP-*specific* — the protocol, which server to run,
what each request does, how a result is shown — is plugin and config.

This is the answer to "a lot of this feels like plugin stuff": it is. The core
`lsp.zig` client + the `nav_ui` consumers (hover/definition/symbols) were core
only because there was no membrane for a plugin to speak a stdio protocol *and*
present results. `dap.js` proves the protocol half; the missing half is a
presentation membrane (jump/edit/decorate/doc-read). Add that, and LSP is a
plugin like the rest.

## core / plugin / config

**Core** (generic, LSP-agnostic — the membrane `lsp.js` stands on):
- proc: `procSpawn` / `procSend` / `onOutput` / `procRead` — already there.
- document read + change feed: the buffer's text and a per-edit notification
  with offsets, so the plugin can send `didOpen`/`didChange` and map positions.
  (NEW membrane.)
- presentation: cursor `jump`, gated `edit`, `decorate` (gutter / underline
  range / virtual-after), `pick` + `onPick`, `echo` / a caret popup. `pick` and
  `bufferAppend` exist for JS; `jump`/`edit`/`decorate`/doc-read are NEW.
- the config store (`weft.config`) and command registration (`weft.command`) —
  already there.

**Plugin** (`lsp.js`) — everything LSP:
- the protocol: `initialize` / `initialized` / `didOpen` / `didChange` /
  `didClose`, and every feature request/notification below.
- **multi-server management** (see next section).
- feature behaviors + their presentation.

**Config**:
- which servers, per language: `weft.set("lsp","zig","zls")`,
  `weft.set("lsp","python","pyright;ruff-lsp")` (a `;`-list runs several).
- keybindings: `K` hover, `gd` definition, `gr` references, `gR` rename,
  `]d`/`[d` diagnostics, `SPC c a` code action, …
- toggles: inlay hints on/off, format-on-save.

## Multiple servers

`lsp.js` owns a table keyed by languageId (derived from the file extension):

    servers = { zig: [connA], python: [pyright, ruff] }

- **Routing.** On buffer focus/open, ensure the server(s) for that language are
  spawned and the document is `didOpen`'d on each; requests for the active
  buffer fan out to that language's servers.
- **Several servers on one language** (a language server + a linter). A request
  that returns a list (references, symbols, code actions) fans out and MERGES;
  a first-wins request (hover, definition) takes the highest-priority non-empty
  answer. This is the capability seam's race/merge policy, now living in the
  plugin.
- **Diagnostics** are keyed by `(uri, serverId)` so each server's set replaces
  independently — two servers' diagnostics coexist on one buffer.
- **Lifecycle.** Servers are lazy (spawned on first use of their language),
  reused across buffers of that language, and share one `didChange` stream per
  open document.

## Features → presentation

| feature | LSP method | shown as (membrane) |
|---|---|---|
| hover | textDocument/hover | caret popup / echo |
| definition | textDocument/definition | jump (or open + jump) |
| references | textDocument/references | pick of locations → jump |
| document symbols | textDocument/documentSymbol | pick → jump |
| workspace symbols | workspace/symbol | pick → open + jump |
| diagnostics | publishDiagnostics (push) | decorate underline + gutter; `]d`/`[d` navigate |
| inlay hints | textDocument/inlayHint | decorate virtual-after |
| code actions | textDocument/codeAction | pick → apply WorkspaceEdit |
| signature help | textDocument/signatureHelp | popup while typing args |
| rename | textDocument/rename | prompt name → apply WorkspaceEdit |
| formatting | textDocument/formatting | apply text edits (or defer to `fmt`) |
| completion | textDocument/completion | feed the completion pick |

WorkspaceEdit application (rename, code actions, formatting) is multi-file
ordered edits through the gated `edit` door — the one part that most wants core
help (open each target, apply bottom-up so offsets hold).

## Migration phases

Each phase is additive + tested against real `zls` (see `src/e2e/shell.nix`),
and removes the core counterpart as the plugin takes over — nothing left behind.

1. **Membrane**: JS `jump`, `edit`, `decorate`, doc-read + change-feed. (Core.)
2. **lsp.js skeleton**: one server, initialize/didOpen/didChange, `hover`.
   Remove `nav_ui.HoverUi` + core `hover` binding.
3. **definition + references + symbols** in lsp.js; remove the `nav_ui`
   consumers + core bindings.
4. **diagnostics** in lsp.js (decorate + `]d`/`[d`); remove the core
   `diagnostics` layer plumbing in `lsp.zig` + the `next/prev-diagnostic`
   builtins.
5. **multi-server** routing + merge.
6. **inlay hints, code actions, signature help, rename, formatting**.
7. Retire core `lsp.zig` once the plugin covers document sync + completion
   (completion is last — it feeds the live-refine pick and is the deepest core
   coupling).

## Status

Phase 0 (this doc). The core `lsp.zig` client + `nav_ui` consumers +
`next/prev-diagnostic` are the pre-migration state being replaced.
