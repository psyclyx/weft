# Place: locus, container, environment

Status: DESIGN (2026-08-28). Requested: multi-project support, then "draw a
distinction between things that go through targets and things that genuinely
need local disc", then "fold the environment overlay in as a first-class part
of place". Builds on `locus.zig` (the locality primitive, already written and
unwired), `semantic_model/durable.zig` (the `weft://` designation grammar,
Wave I), and `Head.working_target` (the target-oriented `cd`, shipped and
almost unused).

This document does not introduce a project concept. Every piece of the
abstraction is already in the tree; what is missing is the wiring, and one
value that was never named.

## 1. The break

Effects resolve against **the process**, not against **the interaction**.

`getcwd()` is the ambient answer to "where does this run" for grep, make, run,
files, LSP, direnv, and agents. `wasm_host/plugin.zig:277`'s `g_environ` — a
`pub var` set once from `main` — is the ambient answer to "with what
environment". Both are read at exactly the same five spawn sites
(`wasm_host/proc.zig:68`, `:185`, `:298`, `:439`; `wasm_host/sessions.zig:37`),
and neither has anywhere to vary.

`locus.zig` states the rule the rest of the tree violates:

> a path or handle is meaningless on its own (rule R1); it means something only
> paired with the locus that hosts it

Five placeholders were cut for this work and left empty:

| Placeholder | State |
| --- | --- |
| `locus.zig` — `Tier{here,peer,shell}`, `Kind{file,dir,proc,…}`, `Resource` | complete; `Loci` never instantiated outside its own tests |
| `Ctx.locus` | captured every dispatch, always `.here` |
| `Facts.locality {local,remote,tool,none}` | declared "so predicates can gate on it"; never set |
| `ctx.zig:293` `workspace` scope | pushed with empty facts; comment names "workspace-multi-root" |
| `Head.working_target` | `action.zig` calls it "the target-oriented analogue of `cd` … applies equally to local, remote, archive, and synthetic hierarchies"; one writer (`SPC v c`), one reader (`open-relative`) whose only caller is a unit test |

The consequence is five disagreeing root detectors, one correct subsystem
(git, via a `cd '{s}'` shell string at `git.zig:2436`), and a `SPC p` prefix
whose bindings mostly do not mean what they say.

## 2. Place

**A place is `(locus, container)`.** That pair is its identity.

- **locus** — `locus.Locus`, the existing opaque tier handle. `here` is the
  sentinel, so the local case is never a branch.
- **container** — a directory-ish target. Live form is
  `semantic.target.Ref` + descriptor revision; durable form is
  `weft://<authority>/dir/<ref>`, which already parses, round-trips, and
  admits `synthetic` kinds.

**Environment is not part of that identity.** It is a property *resolved for*
a place, revision-stamped, published by providers.

This is the one place the brief's "(locus, directory, environment)" wants
splitting. If env were a component of the value, then `direnv reload` — which
changes only the environment — would change the place's identity, invalidating
every session linked to it and every buffer that inherited it. Keeping the
identity to `(locus, container)` means a place is stable and comparable while
its environment moves underneath it. `direnv.zig`'s own header already
specifies exactly this shape: a `direnv.env-for` provider keyed by
`(root, locus, .envrc hashToken)` — a lookup keyed *by* the place, not a field
*of* it.

So: three first-class things, two of them identity and one of them derived.

### 2.1 Where a place lives

Buffer-local, following Emacs's `default-directory`, which is the proven model:

- **`Buffer.place`** — beside `mode` ("restored when this buffer takes
  focus"), `semantic_focus`, and `declared_posture`. Buffer-local state is an
  established pattern in this struct.
- **Inherited at `Buffers.insert`** — the single creation funnel. A tool
  buffer gets its place from the buffer that spawned it, at creation, and
  keeps it. `*grep*` belongs to the project you ran grep in, forever.
- **`Head` pin** — `workspace.set-working-target` already is this, already
  validated (`semantic.zig:715-728` refuses a target the head is not showing)
  and already cleared on system swap.

Effective place = head pin, else focused buffer's place, else the degenerate
local place.

Inheritance is what retires `guest/project.zig`'s last-detected-root kv
singleton. That singleton exists only because a tool buffer has no path to
detect from; inheritance answers the question at the only moment it is
answerable.

### 2.2 The degenerate case is an instance, not a bypass

`Head.working_target` is `?WorkingTarget` today, so every consumer needs a
fallback and the only one available is `getcwd()`. Make the local process
directory an **ordinary container**. Then today's behaviour is the degenerate
instance of the general rule rather than an escape from it — the same move
`locus.zig` already makes with the `here` sentinel, and the same
generalize-the-degenerate-case discipline as the rest of the architecture.

### 2.3 Realization

Places are handles; `chdir` needs bytes. Exactly one gated conversion, modelled
on `app/session.zig:340-365`, whose doc states the contract:

> Activation grants nothing new — the router must still authorize the exact
> revision, and the path is reconstructed from a root this session itself
> opened, so a plugin's opaque target never becomes an arbitrary path.

Realization is host-side, never handed to a guest, and **may refuse**. A peer
or synthetic place has no local cwd; the honest answer is a refusal naming the
place, not a silent run in the wrong directory. That is how remote stays
correct without remote spawn being built.

## 3. Environment as a resolved property

`g_environ` is one global, set once. It needs the same treatment as cwd, at the
same five call sites, and it should ride the same ambient door.

- A provider slot — `weft.provide(slot, predicate, command, prio)` already
  exists with predicates and priority — answers "the environment for this
  place".
- Answers are **revision-stamped**, so a `direnv reload` invalidates rather
  than requiring anyone to poll.
- Resolution layers the place overlay over the base process environment, by
  the same total order everything else uses.
- Applied host-side at the same five spawn sites, so no guest passes it.

This is what makes direnv real, and with it per-project toolchains generally:
nix shells, mise/asdf, virtualenvs, node versions. None can work while the
environment is a single startup global.

**Security note, load-bearing.** Publishing an environment for a place is
equivalent to controlling code execution there — anything that can set `PATH`
for a place owns every subprocess run in it. `direnv.zig` already treats its
own `allow` as TOFU-shaped ("runs arbitrary code on the target host, hence a
deliberate explicit action"). The `env-for` capability inherits that: it must
be granted, config-visible, and surfaced in the approval diff. It is not
ambient authority.

## 4. Machinery, co-located machinery, and content

Three buckets. The test is **can the locus vary?**

1. **Editor machinery — locus is statically `here`.** The wasm module cache
   (`wasm.zig:149`, `WEFT_CACHE_DIR` → `XDG_CACHE_HOME` → `HOME`, test branch
   comptime-pruned), the identity and known-peers keystores, config/plugin/
   grammar/font loading. Plain paths are correct. This is not an exception to
   R1: the locus is a *constant*, so the path carries it implicitly.
2. **Co-located machinery — the locus varies, but it is not user content.**
   git's `.weft-git.patch`, commit-message and rebase-plan files (placed via
   `inRepo()` precisely because "the plugin's cwd is the editor's, which is not
   where the repository is"); `llm`'s prompt file; `ShellFs`'s base64 heredoc
   upload. These must exist wherever the effect runs.
3. **User content** — targets and designations.

Review-time test for 1 vs 3: **provenance**. Bytes the program computed from
its own configuration are machinery; bytes from a user, a document, a peer, or
a provider are content.

### 4.1 Guests may name paths — but it must be the expensive spelling

Not a prohibition. A gradient:

- The place/target form is the **default and cheapest** spelling.
- Raw-path access stays available under an explicit grant, **confined by
  default**. Today `.none` (fully unconfined, falling through to
  `file.readAlloc`) is the default and `fs_root` is opt-in. That is backwards.
- Bucket 1 is carved out **unconditionally**: no grant, however broad, reaches
  the module cache or the keystores. The one place a denylist is right, because
  those paths are program-computed and finite.

### 4.1a A JS plugin must not be ABLE to be a different kind of plugin

Not a rule to follow — a property to make structural. `quickjs.wasm` **is** a
wasm plugin: embedded, compiled through the same `Engine`, instantiated as a
resident guest. A JS plugin is therefore code running inside a wasm guest, and
nothing it does should be expressible outside what a wasm guest can do.

Today that is false by construction. `membrane/qjs_contract.zig` describes
itself as "the `weft.*` membrane's THIRD surface": 33 `qjs_*` imports bound onto
quickjs.wasm's linker, with their own handlers, their own permission checks, and
their own arity table, alongside the 204 `wl_*` doors. Two membranes, maintained
by hand, expected to agree.

They do not, and the divergences are not coincidences — they are what a second
membrane produces:

- `qjs_proc_spawn` grew a `cwd` argument `wl_proc_spawn` never had (removed).
- `cAgentWrite` (`qjs_file_write`) has neither a `requirePerm` nor a path-limit
  check, while its `wl_fs_write` counterpart has both.

Of the 33, **eleven are exact name-twins** of a `wl_*` door — `bind_key`,
`echo`, `log`, `proc_close`, `proc_read`, `proc_send`, `proc_spawn`, `provide`,
`register`, `run`, `semantic_action`. Those are pure duplication: same name,
same meaning, two implementations, two gates.

The cut to make:

- **Plugin-plane doors go through `wl_*`.** quickjs.wasm imports the same
  membrane every other guest does. Then divergence is unrepresentable rather
  than discouraged, and the eleven twins collapse to one each. `hasPerm` is
  already duck-typed across both plane types ("one contract, two transports"),
  which is the precedent the handlers follow.
- **Config-plane doors may stay their own surface.** `config`, `grant`,
  `plugin`, `use`, `set`, `viewport`, `present`, `menu` are the config DSL.
  Config is a distinct *role* with a distinct trust tier — it already chooses
  which plugins load — not a different *kind of plugin*. Keeping that surface
  separate is a real distinction; keeping the plugin plane separate is not.

Until the plugin plane is collapsed, every fix on one side must be applied to
the other in the same change, and the sweep should assert the twins agree.

### 4.2 Better primitives beat bans

The model already ships: `wl_proc_filter` composes
`/tmp/weft-filter-{counter}-{seq}` **host-side** and the guest supplies only
the command, never naming the path (`wasm_host/proc.zig:404-445`). Generalise
that to a **place-scoped spool**: give me scratch at this place, hand the child
its path, clean up after.

Two further primitives close the honest gaps:

- **A marker/ancestor query against a place** — "the nearest ancestor holding
  `.git`", "does `.envrc` exist here". Probing machinery *inside* user content
  is path-shaped by nature and has no target equivalent today; both git and
  `project` open-code it against `fsExists`.
- **kv persistence** (`plans/02-native-surface.md:107`, P12). `kv.zig`'s header
  says state "outlives a run", but `serialize`/`load` have zero production
  callers and both stores die with the process — so `project-recent` silently
  empties on every restart. Until P12 lands, "use kv instead of files" is not
  an argument a plugin author can act on.

The payoff is measurable. `git.zig` declares its grants with the reason
attached: "fs_write drops each draft's message and the synthesized patch into
temp files" and "fs_read: find the repository root, detect an in-progress
rebase." Given a spool door and a marker query, **git drops to `{proc, timer}`**
— the set `direnv` already has. Two capabilities leave the most privileged
plugin in the tree, because the reason it needed them was removed.

## 5. Sessions: identity plus links, not place-keyed tables

CIDER, sly and friends each grew their own session table before Emacs
extracted `sesman`. Its model: a session is a **named object with its own
identity**, and its association to a place is a separate, many-to-many
**link**, resolved most-specific-first (buffer, then directory, then project).

Sessions are not *keyed* by place; they *link* to places. That dissolves the
staleness problem a place-keyed table would have — a descriptor revision bump
breaks a link, not a session — and it yields two REPLs in one project, and one
shared server across two projects, without special cases.

weft is two thirds there. `Instances.current()` already resolves "the instance
owning the focused buffer, else the most recent" — sesman's shape with two
levels instead of three, and with the buffer match done by name-string
comparison (a fragility Wave E already had to cure elsewhere via
`Buffers.resolveSink`). The work is inserting a place link into a chain that
exists.

The timing argument is the strongest one: Emacs got sesman late, after five
tools had entrenched their own tables. weft already has five — git's
`RepoSession`, LSP's `Key`, repl's `Instances`, ACP's conversations, and dap.
This is the same moment.

## 6. The API, and why it is small

The whole behavioural change is an **ambient value read at the door**, not a
parameter threaded through callers. Guests do not pass a place, do not pass an
environment, and do not change.

Precedent for the shape is abundant and consistent: `g_environ` (the same five
sites), `Context.bound_entry` (Wave E — an optional field, an
override-with-fallback reader, a save/restore bracket, no ABI change),
`Context.principal`, and `Head.working_target` itself.
`WasmPlugin.activeCtx()` is non-optional and already called by four of the five
spawn doors.

Counting the alternative is the argument:

| | ambient at the door | parameter per door |
| --- | --- | --- |
| guest call sites changed | 0 | 14 |
| ABI arity / shim / contract edits | 0 | ~24 |
| host edits | ~10, in two files | ~10 |

And the parameter version is worse on the merits, not merely larger: eleven of
the fourteen call sites have **no place to pass**. They would call `weft.cwd()`
and hand the result straight back to the host — an ambient read laundered
through the guest, spreading raw paths into eleven more plugins. Adding
environment then doubles it: a second parameter at every one of those sites.

The naming discipline, from thirty years of evidence: Emacs has
`start-process` (local) versus `start-file-process` (locality-aware), and
`call-process` versus `process-file`. The local-only variant got the shorter,
more obvious name, and the permanent result is a well-known bug class of
packages silently breaking over TRAMP. **The generic form must be the default
spelling; the local-only form must be the one that looks strange.**

## 7. Waves

The sweep is **continuous**, not a final phase. Each wave adds its absence
assertions to `e2e/demolition_test.zig` — which already does exactly this,
"absence assertions over the real source tree", each failure printing its own
file and line, with a STANDING list naming what every survivor awaits. Wave 6
closes the standing list rather than starting the work.

**Wave 0 — pre-flight.** Find every relative-write paired with a relative
shell reference. `llm.zig:39-50` writes `weft-llm-prompt-N.txt` and then shells
`llm < weft-llm-prompt-N.txt`, working only because the fsWrite cwd and the
shell cwd are both the launch directory. Wave 2 breaks that coincidence. (It
also never deletes the file, so it litters the launch directory today.) This
wave must land before Wave 2 or the breakage is silent.

**Wave 1 — Place as a value.** The `Place` type; `Buffer.place` with
inheritance at `insert`; the head pin via the existing `set-working-target`;
the degenerate local place; effective-place resolution; `Context.bound_place`
mirroring `bound_entry`. No effect door changes yet — nothing observable moves.
Gates: two buffers in two projects report different places; a tool buffer
reports its creator's place, not the focused one.

**Wave 2 — Realization and cwd.** The gated place→cwd resolver; the five spawn
sites read the ambient place; job structs carry it, captured at spawn. Honest
refusal for non-realizable places. Gates: grep, build and run act on project B
while weft was launched in A; git's `cd '{s}'` string is deleted; a peer place
refuses with a message naming it.

**Wave 3 — Environment.** The `env-for` provider slot, revision-stamped,
layered over the base environment, applied at the same five sites; the grant
and its approval-diff surface. direnv becomes real. Gates: two projects with
different `.envrc` produce different `PATH` in their builds; a reload
invalidates without a poll; an ungranted plugin cannot publish an environment.

**Wave 4 — Sessions get links.** The sesman model over `Instances`; git, LSP,
repl, ACP and dap converge on it. LSP gains a real `rootUri` per place; ACP's
`session/new { cwd }` stops being `"."`. Gates: two projects, two servers; two
REPLs, one project; a session survives a descriptor revision bump.

**Wave 5 — Better primitives, fewer grants.** The place-scoped spool; the
marker/ancestor query; kv persistence (P12). git drops to `{proc, timer}`; the
five root detectors collapse to one provider. Gates: git declares no fs
capability; recents survive a restart.

**Wave 6 — Close the standing list.** ABI symmetry (an authority parameter on
`fs_read`/`fs_write`/`fs_exists`, as `fs_list` already has); grants confined by
default; the unconditional machinery carve-out; the `fsExists` confinement hole
(its `.fs_root` branch calls the unconfined `file.statKind`, and the gap is
*total* for a `root = "."` grant — which is exactly what root detection uses);
deliberate gating for `grammar-add`.

## 8. Named decisions and risks

- **Environment is resolved for a place, not part of its identity** (§2). The
  alternative makes `direnv reload` an identity change.
- **No project fact.** `Facts` is closed in three independent places at once
  (the struct, the `Predicate` union, the 4-tag guest wire format) and already
  carries four unpopulated fields. Effect doors need to *read* a place, not
  predicate on one. If that ever changes, `intent.zig:341-352`'s catalogContext
  Wyhash fold is the one edit with neither a compiler nor a test guarding it.
- **`Ctx.capture` is provably non-allocating** — by signature (no error union)
  and by a `FailingAllocator` test. A VCS marker walk there is not slow, it is
  inexpressible. The place must be pushed by a provider, never computed at
  capture.
- **`wl_cwd` gets a sibling, not a redefinition.** Its three consumers have
  genuinely different intents: LSP's session key, LSP's URI construction, and
  git's climb floor. Moving them together is a silent-breakage risk.
- **kv persistence is a prerequisite** for the "plugins use kv, not files"
  argument, which is why P12 sits in Wave 5 rather than being assumed.
- **`grammar-add` is not currently a guest escape.** It is ungated and does
  `std.DynLib.open`, but the guest command runners top out at two string
  arguments and it takes three. It is held shut by an ABI arity accident rather
  than by design, which is worth fixing deliberately.
- **JS guests cannot write to disk at all** — `cAgentWrite` writes into a
  buffer and adopts the path, so a later user save creates the file. That
  asymmetry is worth preserving, not levelling.

## 9. Not doing

- No `Project` type, registry, or id. `contextual-workspace-architecture.md`
  §14.8 already assigns "Project resolves roots and project-scoped services" to
  a plugin, and the detection provider is where it belongs.
- No remote spawn. Places that cannot be realized locally refuse and say so.
- No `workspaceFolders` in Wave 4; `rootUri` first, the multi-root LSP protocol
  as its own decision.
- No new fact axis, no new predicate vocabulary, no scoped `weft.set`.
