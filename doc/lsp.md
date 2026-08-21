# LSP as a plugin

## The principle

LSP is JSON-RPC over stdio with `Content-Length` framing — the *same shape* as
DAP (`dap.js`) and ACP (`acp.js`). So it's plugin-shaped, not core: everything
LSP-*specific* (the protocol, which server to run, what each request does, how a
result is shown) is plugin and config; core keeps only the generic primitives a
plugin can't synthesize (subprocess I/O, document read/change, cursor jump,
gated edit, decorate, pick).

This is the answer to "a lot of this feels like plugin stuff": it is. The core
`lsp.zig` client + the `nav_ui` consumers were core only because there was no
membrane for a plugin to speak a stdio protocol *and* present results.

## Substrate: a Zig (wasm) plugin, not JS

DAP/ACP are JS because they're cold — a debug step or an agent turn is
user-paced. **LSP is hot**: `didChange` fires on every keystroke, and
diagnostics / inlay hints / completion stream continuously. quickjs (interpreted
+ GC, JSON per keystroke) would tax that. So `lsp` is a **wasm Zig guest** —
compiled, near-native under wasmtime.

This also lands the membrane cost in the cheaper place. The wasm guest ALREADY
has the rich presentation membrane (`jump`, gated `edit`, `decorate`, `pick`,
`slice`, `cursor`, `lineAt`) — a JS `lsp.js` would need all of that added. The
one thing the wasm guest lacks is a **raw persistent-proc read** (its proc
surface is buffer-oriented: `replStart` streams into a buffer; there's no
`procRead` like JS has). So the membrane work is just: a raw proc channel for
wasm (spawn persistent, `procSend`, `procRead` bytes back to the guest).

JSON in freestanding wasm: `std.json` over a `FixedBufferAllocator` on a fixed
scratch (cap a response at e.g. 256 KiB; parse, handle, reset). Multi-server is
a fixed array of connections. Fixed limits are fine for a client.

## core / plugin / config

**Core** (generic, LSP-agnostic — the membrane the `lsp` guest stands on):
- raw persistent proc: spawn a server, `procSend`, `procRead` bytes back to the
  guest for `Content-Length` deframing. (NEW for wasm — JS already has it.)
- document read + change: `slice`/`byteLen`/`lineAt`/`cursor` exist; the guest
  needs a change signal (or syncs the full doc on request — see phases).
- presentation: `jump`, gated `edit`, `decorate` (gutter / underline range /
  virtual-after), `pick`, `echo` — ALL already in the wasm membrane.
- config store + command registration — already there.

**Plugin** (`lsp`, a wasm Zig guest) — everything LSP:
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

1. **Membrane**: a raw persistent-proc channel for wasm guests (spawn/send/read).
   (Core.)
2. **`lsp` guest skeleton**: one server, initialize / didOpen / sync-on-request,
   `hover`. Remove `nav_ui.HoverUi` + core `hover` binding.
3. **definition + references + symbols** in the guest; remove the `nav_ui`
   consumers + core bindings.
4. **diagnostics** in the guest (decorate underline/gutter + `]d`/`[d`); remove
   the core `diagnostics` layer plumbing in `lsp.zig` + the `next/prev-diagnostic`
   builtins. Switch document sync from sync-on-request to a proper change feed so
   diagnostics/inlay update as you type.
5. **multi-server** routing + merge.
6. **inlay hints, code actions, signature help, rename, formatting**.
7. Retire core `lsp.zig` once the guest covers document sync + completion
   (completion is last — it feeds the live-refine pick and is the deepest core
   coupling).

## Status

Phase 0 (this doc). The core `lsp.zig` client + `nav_ui` consumers +
`next/prev-diagnostic` are the pre-migration state being replaced.
