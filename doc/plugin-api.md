# The plugin API weft wants

Written 2026-08-31, after merging `arc/plugin-resources`. The forcing question:
*what do you want a plugin to be able to do, and does the API make that simple?*
The test case is magit — 3,187 lines that still does less than Emacs's, which is
the tell.

## 0. The finding, in one line

**weft has no primitive for the most valuable kind of plugin — a live,
interactive projection of an external authority — so every plugin in that class
hand-builds the same ~1,400 lines of projection, identity, async demux, and menu
plumbing.** Magit is 3,187 lines of which roughly 500 are about git. Dired is
4,455 lines on the *newer* plane and is not obviously better off. The API is good
at the small stuff and absent at the large stuff, and the large stuff is where
the product is.

## 1. What you want a plugin to do

Eleven kinds, with what is in the tree today and the honest verdict.

| # | Kind | In tree | Verdict |
|---|------|---------|---------|
| A | **Text transforms** — toggle a comment, reindent, pair a bracket, bump a number | `comment` 147, `indent` 91, `autopair` 180, `numbers` 100, `whitespace`, `snippets` | **Served.** ~100-line plugins, clean. `lineAt`/`slice`/`edit`/range handles are the right doors. |
| B | **Input systems** — a modal grammar, a leader tree, a which-key overlay | `vim` 1286, `helix` 233, `emacs` 200, `modes`, `motions`, `operators`, `textobjects`, `which_key` 170 | **Partly.** The keymap doors work. Modes are untyped strings nobody owns; two plugins binding one key is last-writer-wins, silently. |
| C | **Interactive projections of an external authority** — git, a directory, a debugger, a test run, an agent transcript, a container list, a database | `git` 3187, `files` 4455, `debug` 94, `grep`, `make`, `run`, `project`, `notes` | **Not served.** The hole this doc is about. |
| D | **Protocol clients** — LSP, DAP, ACP, HTTP, raw TCP | `lsp` 1678, `net`, `http`, `llm`, `plugin_lib/jsonrpc` 168, `config/plugins/acp.js` | **Partly.** `proc`/`net`/`jsonrpc` are fine; the async model is hand-multiplexed `u32` tokens. |
| E | **Computed services for other plugins** — completion sources, formatters, linters, outline/symbol providers, annotations | `complete`, `fmt`, `ts`, `marginalia` 293, caps registry, slots + D2 | **Served, and it is the best part of the API.** Named slots, composition modes, contextual binding, typed payloads, `Fire` for consumers. This is the shape everything else should look like. |
| F | **UI surfaces** — which-key, the completion popup, pick annotations, a statusline, a minimap, a sidebar, a dashboard | `which_key`, `complete_ui`, `surface*` doors, `semantic view` plane | **Partly, and forked.** Two rival planes (§3 F2), neither of which reaches a text buffer from a model. |
| G | **Asking the user** — a prompt, a fuzzy pick, a yes/no, a transient with infix arguments | `plugin_lib/prompt` 239, `pick*` doors, `palette`, `consult` | **Partly.** Prompt and pick are real. Confirmations and transients are re-hand-rolled by every plugin that wants them. |
| H | **Ambient reactions** — direnv on cd, format on save, reload on watch, detect a project | `direnv` 107, `watch.zig` | **Thin.** `on_activate` and `on_poll` and nothing else. No event bus, no lifecycle hooks. |
| I | **Long-running background work** — an index, a fetch, an agent turn, a build | `make`, `run`, `lsp` | **Thin.** No task or progress primitive; poll plus a token. Background code cannot even `echo` (§3 F5). |
| J | **Persistent state and configuration** | `kvGet`/`kvPut`, `config`/`configList`, `manifest.zig` | **Served.** |
| K | **Replacing core policy** — the editor view itself, a theme, the pick matcher, the scheduler | aspirational; `rendering.md` P5 | **Not yet.** Notably, *themes have no seam at all*: `StyleClass` is a closed 12-value enum and no table maps it to colours. A theme is not currently expressible as a plugin. |

The pattern is stark. **A, E, J are served. C is the hole. B, F, G, H, I are
half-doors.** And C is where a user's day is: git, files, tests, the debugger,
the agent. Everything ambitious in `weft-ui-roadmap`, `agent-support-design`,
and `magit-rebuild` is a C plugin.

## 2. The current API, censused

- **232 ABI doors** in `plugin_sdk/externs.zig`, wrapped by a **2,777-line
  SDK**. The largest single group is `semantic` (43 doors), then `pick` (14),
  `buffer` (10), `slot`/`proc`/`menu` (8 each). The ABI grows roughly one door
  per idea, because the only *generic* spine — slots + D2 schema payloads — is
  used for plugin-to-plugin traffic and never for the built-ins.
- **Two rendering planes.** The old one: a text buffer plus `edit`, `style`,
  `fold`, `decorate`, `readOnlySpan` — all keyed by *byte offset*, all published
  by the plugin. The new one: `semanticViewPublish` — a validated node tree with
  stable ids, host-side focus reconciliation, actions, fields, targets,
  relations — rendered by `view_runtime` (1,384 lines) straight into the frame.
  **The new plane never reaches a text buffer.** So `files` is a widget and
  `git` is text, and they share nothing.
- **The ceremony floor.** Every one of 41 plugins writes `describe()`, `init()`,
  and `on_command(id: u32)` over one hand-maintained table, declared three
  times, dispatched by integer index. 39 of them then write
  `if (id >= cmds.len) return; cmds[id].handler();`.
- **165 `bindKey` calls, 111 `echo`, 85 `run`, 72 `bufPrint`** across the plugin
  tree. `bufPrint` is the tell: 72 sites building strings — mostly shell
  commands — with hand-written quoting.

## 3. Eight findings

### F1 — There is no model-backed view, so every C plugin builds one

`git/render.zig` is 425 lines and **not one of them is about git**. It is:
emit text while tracking your own output offset; record `r_start`/`r_end` per
node into a parallel table; publish styles by offset; publish folds by offset;
linear-scan that table to hit-test the cursor back to a row; find the offset a
node *now* occupies so the cursor can be restored after a re-render; persist
which paths are collapsed across a re-gather. Plus, in `model.zig` and
`root.zig`: a `Target` identity type, a snapshot ordinal, a `resolve` function,
a `refuseStale` path, `markRestore`, `mintName`/`instanceName` for `*git:2*`,
`focusedSession`, and a three-way `Route` enum (`repo`/`focus`/`carried`) that
takes 60 lines of prose to justify.

Every one of those is generic. Dired needed the same things and got them from
the semantic plane — stable ids, host focus reconciliation, no offsets — which
is why `files/projection.zig` is a *pure function* `rows -> scene.Node` and says
so in its module doc. That is the right shape. Git cannot have it, because the
semantic plane does not render to text.

### F2 — The two planes fork the ecosystem

A plugin author's first decision is which plane to build on, and the decision is
irreversible and under-informed:

- **Text plane**: you get search, yank, incremental find, selection within a
  row, a real cursor — and you pay F1 in full.
- **Semantic plane**: you get identity, focus, actions, fields, validation — and
  you lose text. No `/` search, no yanking a diff hunk, no visual-line selection
  to stage three lines of a hunk.

Magit *needs both*, which is why it chose text and paid. This fork is the
single largest structural cost in the API.

### F3 — A command is declared three times and dispatched by index

```zig
export fn describe() void { for (cmds) |c| weft.declareCommand(c.name); }
export fn init()     void { for (cmds) |c| _ = weft.register(c.name); }
export fn on_command(id: u32) void { if (id < cmds.len) cmds[id].handler(); }
```

Repeated 39 times. Arguments arrive positionally and untyped through
`argStr(0)`/`argInt(1)`. Nothing checks that a command's declared arity matches
what its handler reads. Registration order *is* the wire protocol — the comment
in `comment/root.zig` says so out loud: "Registration order == the id the host
hands `on_command`."

### F4 — Keymaps and menus are imperative assertions, and transients are re-invented per plugin

`weft.bindKey("git", "s", "git-stage")` is an assertion into a global table.
There is no owner, no priority, no conflict report, no way for a config to say
"magit's `s`, but `S` means something else here" without knowing magit's
internal command names.

Menus are worse. Git declares **seven menu modes** and ~60 bindings to build
what magit calls a transient. It must reason about the host's mode-stack
internals to do it — there is a 12-line comment in `git/root.zig` explaining
that `git-rebase-menu` must be *sticky* because `dispatch.zig`'s leaf auto-pop
reads "still the same mode after the leaf" as "did nothing, pop it". A plugin
reasoning about the host's dispatch stack is a leak, and it is the
`mode-leak-class` of jank in its purest form.

And the *flag* state — magit's infix arguments, the thing that makes magit magit
— lives in `transient.zig` as plugin-owned booleans painted onto a hand-built
surface, for exactly three commands (push, pull, fetch). Log, diff, rebase,
merge, and blame get no arguments at all. **That is most of what "doesn't do
enough" means.**

### F5 — Async is hand-multiplexed, and background code cannot speak

The pattern is `procToBuffer(cmd, name, token)` where the plugin packs its own
`(session << 8) | kind` into a `u32`, and `on_fill_token(token)` unpacks it into
a switch. Same for `pick_id`. Every asynchronous result in a plugin lands in one
demux far from the code that asked for it, and correlation is the plugin's
problem.

Worse: `weft.echo` is head-gated, so a background completion cannot say a
sentence. Git works around it by *re-entering through a self-registered
command*:

```zig
fn noteDrops() void { ... weft.run("git-note-drops-deliver"); }
```

LSP has the identical workaround. Two plugins independently discovering the same
trick is a missing primitive, not a pattern.

### F6 — The escape hatch is a shell string

Git composes commands with `bufPrint` and hand-written `'{s}'` quoting. A path
containing an apostrophe breaks it. Chaining is `&&`, `;`, `>/dev/null 2>&1`,
and — to recover an exit status the ABI does not return —
`printf '\036\036C%d\n' "$s"` plus `takeEffectOutcome`, which scans the output
stream for a sentinel and splices it out. Every mutation must be fused into one
shell command (`gatherAfter`, `gatherAfterSeq`, `gatherAfterSeq1`,
`gatherAfterPatch` — four near-identical wrappers) purely to avoid an async
read/write race the host could serialize.

There is no "run this argv, in this place, with this stdin, and give me stdout,
stderr, and a status."

### F7 — Fixed scratch and fixed caps make jank a *functional* limit

`git/model.zig`: `MAX_FILES = 128`, `MAX_HUNKS = 512`, `RAW_CAP = 256 KiB`,
`MAX_COLLAPSED = 64`. Exceed any of them and the plugin echoes an apology and
silently drops data — `"git: >128 files — some omitted"`. A `git status` on a
big refactor is *wrong*, not slow.

And `root.zig` carries six module-level scratch buffers, one of which exists
only because two SDK calls alias:

```zig
/// `weft.path` and `weft.placeRoot` both borrow the shim's shared read
/// scratch, so the join needs a buffer neither of them owns.
var probe_buf: [1024]u8 = undefined;
```

A plugin author must know which doors alias which scratch. That is an ABI
ergonomics failure surfacing as a memory-safety hazard in every guest.

### F8 — Extension points are commands, not nodes

Say you want `git-absorb` on the file row under point. Today: fork magit, or
bind a key in git's mode to your own command, then re-derive the row under the
cursor — which you cannot do, because the display table is private to
`render.zig` by design (and an e2e gate scans the source to keep it that way).

There is a good intention layer — `provide(action, When{mode,ext,lang,tool},
cmd, prio)` and published `offers` — but it reaches *the entry*, never *the row*.
The scene plane has exactly the missing vocabulary (`role`, `facts`, `actions`
per node) and no one can reach it from text.

---

## 4. The move

The repo's own method: **find the general thing your first instinct is a
degenerate case of.**

First instinct: *a buffer is text, and a tool plugin renders text into it.*
The general thing: **a view is a published node tree, and the host owns the
projection.** Text is one projection — the degenerate one, a linearization —
exactly as `architecture.md` §"The substrate is stemma's object graph" already
argues for documents.

So: **a plugin publishes a model and the affordances of its nodes. The host
owns rendering, offsets, folding, styling, hit-testing, focus, staleness, and
dispatch. A plugin never sees a byte offset.**

This is not a new plane. It is the semantic view plane, given a **text
projection** so it can absorb the plugins that need one, plus the four
primitives (`exec`, `transient`, `ask`, `task`) whose absence is why C plugins
are large.

## 5. The API — six pieces

### 5.1 `plugin` — the manifest replaces three exports

```zig
pub const plugin = weft.plugin(@This(), .{
    .name  = "git",
    .perms = .{ .proc = true, .timer = true },
});

pub const commands = struct {
    /// Open the git status view for the repository of the current place.
    pub fn status() void { ... }
    /// Stage the file, hunk, or selected lines under point.
    pub fn stage(target: Node) void { ... }
    pub fn checkout(branch: []const u8) void { ... }
};
```

Names, arities, argument types, and summaries come from the declarations.
`describe`, `init`, `on_command`, the `Cmd` table, and the index switch are
generated. Typed parameters mean `argStr(0)` disappears, and a mismatch is a
compile error rather than a silent misread. **Kills F3.** Pure SDK comptime; no
host change.

### 5.2 `View` — the model is the buffer

```zig
const Status = weft.View(Model, .{
    .project = project,        // Model -> Node tree, a pure function
    .backing = .text,          // or .scene; .text renders rows into a buffer
});

fn project(m: *const Model, b: *weft.NodeBuilder) !void {
    for (m.sections) |sec| {
        var s = try b.node(.{
            .id       = .{ .section = sec.kind },
            .role     = "git.section",
            .text     = b.fmt("{s} ({d})", .{ sec.title, sec.count }),
            .foldable = true,
            .affords  = &.{ "git.stage", "git.unstage", "git.toggle" },
        });
        for (sec.files) |f| {
            var fn_ = try s.node(.{
                .id       = .{ .file = f.path },
                .role     = "git.file",
                .text     = b.fmt("{s}{s}", .{ f.status_label, f.path }),
                .foldable = f.hunks.len > 0,
                .affords  = &.{ "git.stage", "git.unstage", "git.discard", "std.open" },
                .facts    = &.{ .{ "path", f.path }, .{ "section", @tagName(sec.kind) } },
            });
            for (f.hunks) |h| _ = try fn_.node(.{
                .id      = .{ .hunk = .{ f.path, h.ord } },
                .role    = "git.hunk",
                .text    = h.body,          // verbatim; the host styles by role
                .affords = &.{ "git.stage", "git.unstage", "git.discard" },
            });
        }
    }
}
```

The host then owns, once, for every C plugin:

| Was, per plugin | Becomes, host-side |
|---|---|
| emit text, track `out`, record `r_start`/`r_end` | render the tree to rows |
| `publishStyles` by byte offset | style by `role`, through a **theme table** (which also makes K expressible) |
| `publishFolds`, `setCollapsed`, `collapsedIndex` | fold by node id; fold state keyed by id, survives re-render |
| `nodeAt`, `nodeAtCursor`, `hashTokenAt`, `commitRow` | hit-test cursor → node id |
| `offsetOf`, `markRestore`, `restore_target` | focus reconciliation by id (`view_runtime` already does this) |
| `Target`, `snapshot`, `resolve`, `refuseStale` | the view's revision; an action against a stale revision is refused at the door |
| `mintName`, `instanceName`, `focusedSession`, `Route` | a view is a handle; an event arrives with the view it happened in |
| `MAX_FILES`, `MAX_HUNKS`, fixed scratch | an arena per projection; the model is whatever fits memory |

A `.text` view keeps everything text gives you — search, yank, visual selection.
A selection inside a node comes back as **node id plus line ordinals**, never as
offsets, which is exactly what partial-hunk staging needs and what
`selectedLines` computes by hand today. **Kills F1, F2, F7.**

### 5.3 Affordances — the node *is* the offer table

A node lists the intentions it affords. That single fact replaces:

- `publishOffers` and its six call sites — a fresh tree is a fresh offer table,
  published by construction;
- most `bindKey` calls — the keymap binds `s → "git.stage"` *once*, and the host
  resolves it against the node under point, with the node's own reason when it
  affords nothing;
- the staleness dance — the tree carries the revision.

And it opens F8: another plugin does

```zig
weft.provide("git.absorb", .{ .role = "git.file" }, commands.absorb, 10);
```

and gets a verb on magit's rows, with the row's `facts` as its arguments,
without magit knowing it exists. **Kills F8, most of F4.**

### 5.4 `exec` — argv, not a shell string

```zig
const r = try weft.exec(.{
    .argv  = &.{ "git", "add", "--", path },   // no quoting, ever
    .cwd   = .place,                           // where, as a value
    .stdin = patch,                            // spooled by the host if a path is needed
});
// r.status, r.stdout, r.stderr — as fields, not sentinels in a byte stream
```

Returns a future (§5.6). Effects on a view serialize per view, so
`mutation && GATHER` fusion — and `gatherAfter`, `gatherAfterSeq`,
`gatherAfterSeq1`, `gatherAfterPatch`, `takeEffectOutcome`, and the
`\036\036C%d` protocol — all go away. A view invalidated by an effect
re-gathers once, after. **Kills F6.**

### 5.5 `transient` — infix arguments as a value

```zig
pub const push = weft.transient(.{
    .title = "Push",
    .args  = .{
        .force    = .{ .key = "-f", .flag = "--force-with-lease" },
        .upstream = .{ .key = "-u", .flag = "--set-upstream" },
        .remote   = .{ .key = "-r", .value = .{ .prompt = "remote", .default = "origin" } },
    },
    .actions = .{
        .{ .key = "p", .label = "push", .run = doPush },
        .{ .key = "e", .label = "push elsewhere", .run = doPushElsewhere },
    },
});

fn doPush(a: push.Args) void {
    _ = weft.exec(.{ .argv = a.argv(&.{"git", "push"}), .cwd = .place });
}
```

The host owns the overlay, the sticky/one-shot semantics, the argument state,
and the persistence of arguments across invocations. No plugin declares a menu
mode; no plugin reasons about dispatch's leaf auto-pop. **Kills the rest of F4,
and the mode-leak class with it.** It also *adds* what magit is missing: infix
arguments become available to log, diff, rebase, merge, and blame for free,
because they are declarative and cheap.

### 5.6 `ask` and `task` — futures instead of token demux

```zig
if (try weft.confirm("discard this hunk?")) discardHunk(h);

const branch = try weft.prompt(.{ .label = "checkout branch", .complete = branches });

const t = weft.task("fetching");   // progress a UI can render
defer t.done();
```

A future resolves in a dispatching context by construction, so background code
can `echo` — and `git-note-drops-deliver` and LSP's twin workaround both
disappear. The `u32` token packing, `on_fill_token`, `on_pick_accept`, the
`Confirm` enum, and `confirmPick`/`confirmThen` all go. **Kills F5.**

## 6. Magit, before and after

| Concern | Now | After | Why |
|---|---|---|---|
| Parse status/diff/log | `parse.zig` 169 | **169** | Real git work. Unchanged. |
| Synthesize a partial patch | `patch.zig` 133 | **133** | Real git work. Unchanged. |
| Domain model | `model.zig` 412 | **~110** | Sessions, targets, snapshots, render tables, fixed caps → a plain arena-built tree. |
| Projection | `render.zig` 425 | **~70** | A pure `Model -> Node` function. |
| Shell orchestration | `gather.zig` 127 | **~15** | Four wrappers and a sentinel protocol → `exec`. |
| Transients | `transient.zig` 131 + ~60 binding lines | **~55** | Declarative, and covers *every* command instead of three. |
| Commands, verbs, offers, drafts, rebase, confirm, routing | `root.zig` 1790 | **~330** | Manifest, affordances, futures, and host-owned identity. |
| **Total** | **3,187** | **≈ 880** | |

That is the estimate, and it is an estimate — but the load-bearing part is not
the ratio, it is *which* lines vanish: everything in the "after" column that
shrinks is generic code that ten other plugins also have to write.

And the functionality goes **up**, not down:

- no `MAX_FILES`/`MAX_HUNKS`/`RAW_CAP` ceiling — a large status is correct;
- infix arguments on log, diff, rebase, merge, blame — the actual magit gap;
- per-hunk folding (currently deferred: "hunk-granularity folds are a later
  phase") is free, because folding is by node;
- third parties can add verbs and decorations to git's rows;
- a theme can restyle a diff, because styling is by role.

The `git` plugin that remains is: parse git's output, synthesize patches, name
the commands, and describe what each row affords. That is what a git plugin
should be.

## 7. What this makes structurally impossible

Per `structural-impossibility` — these are bug *classes* deleted, not patched:

1. **Acting on a stale row.** Offsets never cross the membrane; an action names
   a node id and a revision, and the host refuses a superseded one.
2. **Mode leaks.** No plugin-declared menu modes, so no plugin can strand you in
   one. A view's resting posture is a property of the view.
3. **Silent key collisions.** Keys bind to intentions; two providers of one
   intention is a resolution the host can report, not a table overwrite.
4. **Shell injection and quoting bugs.** `argv` has no quoting.
5. **Truncated models.** No plugin-side fixed caps to overflow.
6. **Aliasing scratch.** Owned slices from an arena; no shared shim scratch to
   trip over.
7. **Mute background work.** A future resolves where it is allowed to speak.

## 8. Costs, told straight

- **This is a large change.** Six primitives, a text projection in
  `view_runtime`, a theme table behind roles, and a migration for 41 plugins.
  The migration is incremental — the old doors keep working — but "incremental"
  over 41 plugins is still a campaign on the scale of `phase3-campaign`.
- **The text projection is the hard part.** Rendering a node tree to rows with
  stable folding, incremental re-render, and selection that maps back to node
  ordinals is real work in core, and it is the thing that must be right or
  everything above it wobbles.
- **`exec` with `argv` loses shell composition.** Some plugins genuinely want a
  pipeline. Keep a `.shell` variant, explicitly named as the unsafe door, and
  let the gate assert that no in-tree plugin uses it for a path.
- **Affordance resolution adds a lookup to every keypress.** It should be a
  table walk on a tree the host already holds, but it is on the input path and
  wants a benchmark, not an assumption (`weft-test-gates`, `perf`).
- **It does not fix D, H, I.** Protocol clients, ambient reactions, and
  background tasks get better (futures, `task`) but not solved. An event bus and
  a real task/progress model are separate work.
- **It does not, by itself, deliver K.** Roles-plus-theme-table makes a theme
  plugin possible; the editor view as a slot is still `rendering.md` P5.

## 9. Phasing

Each phase compiles and leaves the tree green; each is useful alone.

1. **`plugin` manifest** (SDK-only comptime). Delete the three-export ceremony
   across 41 plugins. No host change. Cheap, immediate, low risk.
2. **`exec`** (host + SDK). argv, cwd, stdin, status/stdout/stderr, futures.
   Migrate git and `make`/`run`/`grep`. Deletes `gather.zig` and the sentinel
   protocol; retires 72 `bufPrint` sites' worst offenders.
3. **`ask` / futures.** `confirm`, `prompt`, `pick` as futures; background echo.
   Deletes the token packing in git and lsp.
4. **Text projection for semantic views.** The core work: render a node tree to
   buffer rows, fold and style by node, hit-test, reconcile focus, report
   selection as node + ordinals. Prove it by porting **one** view — `debug` (94
   lines) or `grep` (116) — end to end.
5. **Affordances on nodes** + intention resolution against the node under point.
   Prove it with a third-party verb on the ported view's rows.
6. **`transient`.** Prove it by replacing git's seven menu modes.
7. **Port magit.** The 3,187 → ~880 rewrite, as the acceptance test for all six.
8. **Port dired** onto the same text projection, retiring the fork in F2.
9. **Theme table behind roles** — K becomes expressible.

Steps 1–3 are worth doing whatever happens to the rest: they are small, they are
pure deletion, and they do not depend on step 4.

See [[plugins-not-core]], [[structural-impossibility]], [[magit-rebuild]],
[[mode-leak-class]], [[rendering-decomplection]], `architecture.md`,
`rendering.md`, `d2-schema-payloads.md`.
