# weft — Dispatch architecture

How an intent gets from an input event to a concrete effect. Three tiers over
one idea (resolve the best entry by context + priority), so a plugin composes by
declaring data, never by wiring a central switch.

```
input ─(1 keymap: layered key→name)→ NAME ─(2 action: providers·when·priority)→ command ─(3 registry: name→handler)→ effect
```

The tiers are separable on purpose: **keys are preference, intents are
semantics, implementations are context.** Each evolves without touching the
others. A key can also bind straight to a Tier-3 command (skipping Tier 2) when
the effect is concrete (`save`, `cursor-down`); the action tier is for intents
whose implementation depends on *where you are*.

---

## Tier 1 — Keymap (input → name)

`src/core/Keymap.zig`. A pure string table: `mode → key → name`, where the name
is a command or an action (both resolve through the same door, Tier 3). Layered:

- **priority tiers** — `core (−100) < plugin (0) < config (100)`. A bind takes
  the slot only when its priority ≥ the incumbent's, so the resolved keymap is a
  pure function of the declaration set, never load-order-dependent. Equal
  priority from two different owners is a *collision*, surfaced as a warning.
- **fallback chain** — `mode → parent`, walked at lookup (vim `visual` falls
  back to `normal`). A menu/tool mode with no parent is an island by design.
- **the global layer** — a reserved `global` mode consulted after a mode's own
  fallback chain, so a universal key (F1 which-key, `C-w` window prefix) works
  under *every* mode without being copied into each, while any mode still
  overrides it locally. It is the final check, never a fallback target (so it
  can't leak a whole mode's bindings in).

The keymap deliberately holds **no context predicate of its own.** All
context-sensitivity lives in Tier 2: to make a key do different things in
different buffers you bind it to an *action*, not to a `when`-gated keybinding.
This is a deliberate choice against VSCode-style `when`-clauses on bindings —
binding a key to a `when`-scoped action is strictly more composable (many
plugins contribute providers; the winner is a pure function of context) and
keeps keymap lookup a fast, total table walk.

---

## Tier 2 — Actions (name → provider)

`src/core/action.zig`. The middle tier, and the extensibility payoff. An
**action** is an abstract intent (`eval`, `format`, `run`, `test`,
`references`) that many plugins **provide** for. Each provider carries:

- a **`when`** predicate — the ambient facts that must hold. v1 vocabulary is
  `{ mode?, lang? }` (conjunction; absent = don't-care). `lang` is the active
  buffer name's extension. The shape is small and grow-only: a provider list is
  already an OR across providers and priority is already override, so
  disjunction/negation are a later addition, not a rewrite.
- a **priority** (i32), and an **owner** (plugin/config name, for teardown).

**Resolution** (`resolve(name, ctx)`) picks the highest-priority provider whose
`when` holds; ties break toward the **more specific** predicate (a `lang:zig`
provider beats an unconstrained default at equal priority), then later
registration. Pure function of the provider set and the context.

**Two policies:**

- **`pick`** (implemented) — run the single best applicable provider, now,
  synchronously. This is the "synthetic bind": bind `SPC e → eval` once; a `.zig`
  buffer runs `zig-eval`, a `.py` buffer `python-repl`, everything else the
  default — and a new language plugin just registers another provider, no
  rebinding. No applicable provider ⇒ a graceful echo (`no eval provider for
  .md`), never a failure.
- **`race`** — the async fan-out embodied by the **capability system**
  (`src/core/capability.zig`): completion/hover/definition fire every matching
  provider and merge results over time against a stamped document version. This
  is the *same* "resolve by context + priority" idea at a different latency. The
  capability call sites route through `Context.fireRace`, which records the kind
  as a race action here (so every intent, pick and race, is enumerable in one
  registry) and drives `Caps`. Race *resolution* stays the capability system's
  job, not the pick provider list — so a `provide()` (a pick command provider)
  on a race action is refused; register a capability provider through the
  capability ABI instead. The consumer UIs own the session/poll lifecycle;
  `fireRace` owns the dispatch entry.

**Actions ride the command door.** Declaring an action registers a same-named
*trampoline* `Command` (`command.registerAction`) that resolves the provider
against the live context (`Context.actionCtx()` = active mode + active buffer
lang) and tail-calls the winner. So the keymap, ex commands, the palette, and
programmatic `command.run` all dispatch actions uniformly — there is no bespoke
firing path, and an action is invocable anywhere a command is.

---

## Tier 3 — Commands (name → handler)

`src/core/command.zig`. The concrete leaf: a name, a typed argument schema
derived from a Zig function at comptime, and a handler over the portable value
ABI. Late-bound (resolution happens at call time, so a bind may name a command a
plugin provides later). Every mutator crosses one door — `Context.edit` — which
gates by the invoking principal's grade and routes to the user's undo history or
the plugin peer's, so authority and selective-undo hold across the membrane.

---

## The ABI surface

Config (`config.js`, quickjs) and wasm plugins share the same shape:

| | config (JS) | plugin (Zig guest) |
|---|---|---|
| declare intent | `weft.action("eval")` | `weft.declareAction("eval")` |
| register provider | `weft.provide("eval", {lang:"zig"}, "zig-eval", prio)` | `weft.provide("eval", .{ .lang="zig" }, "zig-eval", prio)` |
| bind a key | `weft.bind("normal", "space e", "eval")` | `weft.bindKey("normal", "…", "eval")` |

`provide` auto-declares (load order is free). A plugin's providers are owned by
its name and torn down with it (`actions.unregisterByOwnerPrefix`); the declared
action name persists (cheap, another provider may still target it).

---

## Why this is the spine

- **Composition without a switch.** A language plugin adds an `eval` provider
  and the existing `SPC e` starts working in its buffers — no core edit, no
  keymap edit. The winner is data, resolved by context.
- **One resolution idea, three uses.** Priority-ordered, context-predicated
  selection powers keymap layers (priority + fallback + global), action
  providers (`when` + priority), and — as `race` — the capability system. They
  are the same shape at three latencies, not three bespoke mechanisms.
- **Keys, intents, and impls stay orthogonal.** Rebind without touching
  semantics; add a language without touching keys; swap an implementation
  without touching either.

## Open increments

- Grow the `when` vocabulary as real needs appear (buffer read-only, a named
  capability's presence, disjunction) — additively, never a rewrite.
- Optionally let a race action's providers be `when`-scoped at the action tier
  (e.g. a markdown buffer's `hover` renders the link; code's is LSP), layering
  the pick predicate over the capability fan-out.
