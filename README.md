# weft

> **weft** /wɛft/ *n.* — the crosswise threads woven over and under the warp
> on a loom to make cloth.

weft is a programmable editor for code and prose, written in Zig. It uses
[stemma](https://github.com/psyclyx/stemma) for collaborative document state
and runs on Linux with Wayland, Vulkan, and Skia.

Text editing, file browsing, Git, command output, and agent
conversations share a workspace. Plugins supply the editing modes and tools;
JavaScript config chooses how they fit together.

## What it does

- **Code and prose.** Tree-sitter highlighting, structural navigation, LSP
  completion, diagnostics, and refactoring. Markdown renders with proportional
  text, styled headings, and inline formatting while remaining editable source.
- **Editing modes.** Vim, Helix, and Emacs-style plugins. The sample config uses
  Vim with Space-prefixed bindings, a command palette, and key hints.
- **Project tools.** An editable file browser, Git status and staging, project
  search, formatting, build commands, REPLs, and notes. Tool views support
  structured rows, folding, and actions on the item under the cursor.
- **Agents and debugging.** ACP agent conversations and DAP debug sessions run
  through plugins. Agent and debug adapter commands are configured explicitly.
- **Collaboration.** Edit a shared document with other peers, see their cursors,
  or serve it from a headless host using the same executable.

## How it fits together

Documents are stemma object graphs. A plain file is a document containing one
text object; a transcript has structured entries with text bodies. Views present
that data as editable text or structured rows. Filesystem and Git views talk to
their respective owners, with pending edits kept as drafts.

Document state uses a CRDT: concurrent edits merge, positions stay attached to
the text they refer to, and each peer can undo its own changes without undoing
someone else's. Edits carry an author, including edits from plugins and agents.

A **locus** identifies where a resource lives: here, on a connected weft peer,
or through a remote shell. A **place** pairs a locus with a working container,
such as a project directory. Buffers carry their place, and tool buffers inherit
it, so commands use the relevant project's directory and environment. An
operation that requires a local directory refuses a remote place it cannot
serve.

Permissions describe who may do what. Document grants are `view` (read), `edit`
(read and write), or `own` (currently edit, reserved for administrative authority).
Filesystem, process, and network capabilities are granted separately and checked by the
host. Filesystem permissions default to the current place; config can set an
explicit root. Sharing a document does not grant access to the rest of its
project or permission to run commands there.

Plugins run in WebAssembly under Wasmtime. JavaScript plugins and config run
in QuickJS inside that sandbox. The reference plugins are installed as separate
files. Starting without a file opens the dashboard plugin; editing remains
modeless until a config or explicit plugin selects an editing mode.

Config selects plugins, grants permissions, binds keys, and arranges views.
Bindings can express an action such as save or open, with the focused view
providing the appropriate behavior.

## Run it

The Nix shell supplies Zig 0.16 and the native build dependencies. Opening a
window requires a Wayland session and Vulkan support.

```sh
nix-shell
zig build run -- --config config/config.js README.md
```

Omit `README.md` to start on the dashboard. The `--config` flag matters:
`zig build run -- config/config.js` opens that JavaScript file for editing.
The sample dashboard config defines ordered sections as
`id<TAB>title<TAB>source-command<TAB>open-command<TAB>limit` records. A
source command returns newline-separated candidates; the dashboard shows at
most `limit` rows and passes the selected candidate to the open command.
Static actions use `id<TAB>label<TAB>command<TAB>optional-argument` records
in `dashboard.items`.

With the sample config, `SPC SPC` finds a file, `SPC :` opens the command
palette, and `SPC f s` saves. See [config/config.js](config/config.js) for
bindings, plugin choices, language servers, and agent/debug adapter settings.

To start without the sample config, or load a plugin directly:

```sh
zig build run -- README.md
zig build run -- --plugin vim README.md
```

Plugins can also be loaded with `weft.plugin(name)` in config. Named plugins
resolve under `lib/weft/plugins/` beside the installation; `WEFT_PLUGIN_DIR`
overrides that directory.

The Nix package is available as `packages.weft` from `default.nix`. Arch and
Debian package recipes use the same build; see [packaging/README.md](packaging/README.md).

Set the startup text size with `weft.set("editor", "font-size", "16")` in your
config, or use `--em 16` without a config. `Ctrl++` (or `Ctrl+=`) and `Ctrl+-`
adjust it while editing; `Ctrl+0` restores the configured size. The command
palette also offers `font-size-set <size>`, `font.increase`,
`font.decrease`, and `font.reset`.

## Share a session

With the sample config, use `:` to run these commands, or open the command
palette with `SPC :` and enter them without the leading colon.

In the host editor, focus the document to share and start listening:

```text
:collab.listen 7777 edit
```

In the other editor, replace `HOST` with the host's address:

```text
:collab.connect HOST:7777
```

The host's document opens as a new buffer. To share another document, focus it
and run `:collab.share pair`. Use `:collab.peers` to see connected peers and their identity
fingerprints and verification words. `:collab.share-presence off` hides your cursor;
`:collab.disconnect` leaves the host while keeping the shared buffers locally.

Connections are encrypted and use the token supplied at startup with `--token`;
both editors must use the same value. `collab.listen` takes an explicit access grade:
use `view` instead of `edit` for read-only access. Filesystem sharing is a
separate grant. See [the wire protocol](doc/wire.md) for details.

For a headless host, the same executable also accepts startup flags:

```sh
zig-out/bin/weft --headless --listen 7777 --token YOUR_TOKEN --access edit file.zig
```

## Development

```sh
zig build test          # unit, integration, and offscreen editor tests
zig build test-contract # focused schema, semantic, and filesystem contract tests
```

The render tests use the production renderer with offscreen Vulkan images and
need no display server. To record the two-editor demo, with `ffmpeg` available:

```sh
WEFT_E2E_VIDEO=/tmp/weft-demo.mp4 zig build e2e-demo
```

stemma is pinned to a release. When working in the monorepo, use
`NPINS_OVERRIDE_STEMMA=../../lib/stemma` to build against its local checkout.

The [plugin API](doc/plugin-api.md) and
[workspace architecture](doc/contextual-workspace-architecture.md) cover the
design in more detail. Architecture documents also describe planned work.
