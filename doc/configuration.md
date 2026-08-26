# Configuration

Status: design, 2026-08-26. Companion to `contextual-workspace-architecture.md`
(the architecture owns three invariants restated in §2 below; this document
owns everything else about configuration). Rationale and the decision walk:
`cwa-config-decisions.md`. Motivating example and acceptance test: the generic
sidebar.

New decisions taken here (vetoable): the binding fallback-list arity (§5.2),
the single naming grammar (§5.1), the instance-plane scoped-value form (§6),
and project-tier placement (§7.3).

## 1. The model in one paragraph

Configuration is a plugin with no special powers. A config file is a program
that runs once, sealed — deterministic, injected clock, no ambient I/O — and
evaluates to a **manifest value**. The manifest, plus its hash, is the
artifact: approval binds to the hash, and a re-evaluation that produces a
different manifest invalidates approval (this closes time-of-check /
time-of-use on the approval diff). Declaration order within one file is
authored data (it feeds the total order, §7.2), but nothing depends on *when*
a declaration ran — a manifest is a value you can diff, name, nest, and swap,
not a script that happened.

## 2. What the architecture doc owns (restated, not redefined)

1. Resolution inputs are manifest data — bindings, provider registrations,
   slot overrides, placements, predicates, grants — so that `explain()`,
   which-key, and the approval diff can read them without executing anything.
2. Config-registered runtime providers are ordinary principals at the config
   tier: no special powers, no invisible interposition, normal grants, normal
   appearance in resolution traces.
3. Sealed evaluation plus the manifest hash is the trust boundary.

## 3. The line: where code is welcome

Two orthogonal distinctions, not a code-vs-data rule:

- **Eval-time vs runtime.** Code that computes the manifest is unlimited and
  idiomatic — a loop generating twelve bindings is programming-the-manifest.
  What must *end up as data* is anything resolution or approval reads (§2.1).
- **Provider vs interposer.** Config may register runtime code — a statusline
  segment, a placement policy, a follow-focus loop, a one-off action. That is
  a small plugin living in a config file, paying normal plugin costs. What is
  refused is code that *intercepts* rather than *provides*: undeclared hooks
  wrapping other plugins' dispatch, or anything in the keystroke path outside
  a declared slot.

> Code is welcome at eval time and welcome as a declared provider in a slot;
> it is refused as an undeclared interposer.

Friction — behavior that fits no slot — is a signal that a slot is missing,
not a license to hook. And because config and plugins are the same thing, a
provider that grows up **graduates by moving to a file**, with zero semantic
change. That is the intended prototyping path.

## 4. Three planes

- **Manifest plane** — declarations feeding resolution and approval (§5).
  Sealed-eval, hash-approved.
- **Instance plane** — scoped options on live things (§6): "*this* sidebar's
  Files view hides dotfiles." Data, resolved by the same most-specific-wins
  machinery, not part of the approval hash (no authority flows through it).
- **Content plane** — parameters stored inside resources, such as a note
  embed's view parameters. Owned by the embed contract
  (architecture §11.8), not by this document.

## 5. The manifest plane

### 5.1 One naming grammar

DECIDED (vetoable): one grammar, dotted segments.

- `std.<package>.<operation>` for standard protocol packages and their
  intentions — `std.hierarchy.toggle-expanded`, `std.target.activate`,
  `std.history.undo`, `std.persistence.save`. In binding-table prose the
  `std.` prefix may be elided (`hierarchy.toggle-expanded`), never in wire or
  manifest values.
- `plugin.<id>.<...>` for plugin-specific protocols and operations.
- `ui.<slot>` for UI capability slots (`ui.gutter-segment`, `ui.layout`,
  `ui.placement-policy`) — the slash forms in `capabilities.md` and
  `rendering.md` (`edit/completion`, `ui/overlay`) are legacy spellings that
  migrate at their area's phase.

Versions ride the protocol identity (`@N` where it matters on the wire), and
the protocol name is the major-version unit (architecture §17 Phase 1).

### 5.2 Declarations

The existing verbs persist with their meanings — `weft.plugin(name, {grants})`,
`weft.use(fragment)`, `weft.provide(slot_or_action, predicate, provider)`,
`weft.action(...)` — with these additions and corrections:

- **`weft.bind(scope, key, intention | [intentions])`** — the third argument
  may be a list, authored fallback resolved before invocation
  (architecture §10.2). This is the missing arity: without it the config
  surface cannot express `Return -> [target.activate,
  editing.insert-line-break]`, and the end-state config would ship the §2.2
  bug intact. `scope` names an input-grammar state (a grammar-owned name, per
  viewport instance), not a global mode.
- Bindings target **intentions**, not concrete plugin commands. Binding a
  concrete command remains possible only through the legacy allowlist
  (architecture §17) and disappears with it.
- **`weft.viewport(name, {attributes...})`** and
  **`weft.present(viewport, {subject, presentation, options})`** — the
  workspace-composition declarations (attributes per architecture §7;
  `subject` is a durable target or a provider-computed value). A "sidebar" is
  a fragment bundling these.
- **Action contracts, not bare names.** A declared semantic action carries
  its contract (schema, shapes, effect grade — architecture §9.1);
  `{ name }`-only declarations are legacy.
- **`weft.grant` requests** surface in the approval diff, which renders from
  the authenticated grant descriptors, never from labels the fragment
  supplies (architecture §13.6). Third-party fragments' grants always
  surface.

### 5.3 Runtime providers in config

`weft.provide(slot, predicate, fn)` with a function value registers a
config-tier provider: it runs as the config principal, under the granted
caps, at config-tier precedence, visible in traces as itself. The follow-
focus loop, an exotic placement policy, and a custom statusline segment are
the intended uses. There is no hook verb and there will not be one.

## 6. The instance plane

`weft.set(scope, owner, key, value)` — scoped values, most-specific-wins over
the scope stack (system → project → workspace entry → viewport attachment),
resolved by the same machinery as everything else. The legacy three-argument
`weft.set(owner, key, value)` means global scope. Instance values carry no
authority and are not part of the approval hash; a provider reads them
through its declared options schema, so unknown keys are inert and typos are
reportable.

Theming is instance-plane data at system scope (`theme` role→value bindings,
first-wins with config priority), consumed by the renderer per
`rendering.md`; a colorscheme is a fragment of such values.

## 7. Fragments, tiers, and the total order

### 7.1 Fragments

`weft.use(fragment)` imports a manifest fragment (defaults, a colorscheme, a
sidebar, an editor profile). Fragments are values; they nest.

### 7.2 The total order

All name/priority resolution — providers, bindings, placements, slots, facts
— uses one deterministic total order:

```text
(tier, priority, specificity, owner fingerprint, declaration index)
```

- Tiers: `core < imported < plugin < config < transient`. **An imported
  fragment lands one tier below its importer**, so `weft.use("defaults")`
  followed by your own binds overrides deterministically, at any nesting
  depth.
- Within one owner, declaration index decides: a manifest is a list, and its
  order is authored data.
- **Shadow vs collision:** an intentional override across tiers (or an
  explicit higher priority) is a *shadow* — normal and silent. Equal
  `(tier, priority, specificity)` from *different owners* with overlapping
  predicates is a *collision* — a load-time error with both provenances,
  never a quiet winner.
- `explain(slot, context)` answers from this order alone; nothing executes.

Sessions pin: the order governs new resolutions, never migrates an in-flight
feed or service (architecture §8).

### 7.3 Project configuration

A project may carry a manifest fragment at the `project` position inside the
config tier (above `imported`, below the user's own config). Project
fragments are third-party by default: their grants and providers always
surface in the approval diff, and approval is per (project, manifest hash).
Instance-plane project values (§6) apply without approval; manifest-plane
project declarations never do.

## 8. Systems as manifests

`weft.system(name, fragment)` names a composition — which plugins fill which
slots in which contexts. Switching editor→agent-UX is re-binding a system's
slots, not a mode flag; a zero-head daemon is a system with no head attached.
Systems are values: name, swap, nest. (The runtime mechanics are the
container's; this document only fixes that config *declares* systems and
never imperatively assembles them.)

## 9. Acceptance tests

- The sidebar gate (architecture §18): a docked sidebar showing project
  files, document symbols, or tree-sitter objects is a fragment over the
  generic tree presentation — no interposing behavior, everything visible to
  explanation; following logic may be a few lines of declared provider code.
- A fallback-list binding resolves and explains: which-key shows the winning
  arm and the rejected arms with reasons.
- Re-evaluating an unchanged config reproduces the identical manifest hash;
  any drift invalidates approval visibly.
- A provider prototyped in config moves to a plugin file with no semantic
  change and no re-binding of its consumers.
- A third-party fragment cannot acquire a grant that never appeared in an
  approval diff, and the diff text is derived from the grant value itself.

## 10. Open questions

1. The exact viewport attribute set and options schemas (shared with
   architecture §20-remaining 1–2).
2. Whether instance-plane writes are themselves undoable (a settings history
   protocol) or fire-and-forget.
3. Fragment distribution and pinning (files-in-place today; anything more is
   out of scope here).
