# D2 — schema-directed payloads: the crossable value type for open slots

Status: DESIGN (2026-08-22). Due in-phase W5 (north-star-plan §6). This doc
discharges deliverable **D2** and the fork **F6**, both DECIDED
(north-star-plan §5, user: "lean in to c"): schemas are VALUES carried by the
`SlotDecl`; both ends marshal by schema-direction; the host is a table-driven
interpreter for runtime-declared slots; guest SDKs may CODEGEN typed bindings
from the same schema value; anchors/ranges are schema-MARKED fields so the
host restamps versions inside payloads it otherwise doesn't understand.
"Compact like bespoke marshalling, restampable like a tagged encoding."

The fork is not relitigated here. This is the full design: the schema
language, its value representation and carriage, the marshaller (both
directions), restamping, migration off the closed union, the third-party-UI
payoff, and the boundaries told straight.

Method note (matching the plan): everything below was checked against the
code, not the docs. Where the decided design meets code that resists it, the
resistance is recorded, not smoothed over.

Labels: **DECIDED** (by §5 F6, or forced by an invariant), **DESIGN** (this
doc's call, build-ready), **HYPOTHESIS** (a plausible shape, not yet forced).

---

## 1. Ground truth — the closed payload today

The wall C18 names is not the slot NAME space (the Container opened that:
`container.zig` resolves any declared slot name). It is the payload TYPE
space. Three closed facts, cite-for-cite:

- **`capability.Payload` is a closed union of five shapes**
  (`capability.zig:200`): `completion: []CompletionItem`, `text: []u8`,
  `locations: []Location`, `symbols: []Symbol`, `edits: []Replacement`. A
  guest-declared slot with a novel result shape has no sixth member to be.
- **The union is hand-walked in three places** — `dupePayload`
  (`capability.zig:746`), `restamp` (`:734`), `Result.deinit` (`:217`). Each
  is a `switch` over the five tags. A new payload shape means editing all
  three by hand. This is exactly the drift class W0a's `contract_data.zig`
  killed for the CALL surface, reappearing on the PAYLOAD surface.
- **The guest→host push is completion-shaped.** `wl_caps_item`
  (`contract_data.zig:246`) is an eleven-parameter import hard-coded to a
  completion item's fields (text/label/detail/kind/doc/rank);
  `wasm_host/capability.zig`'s `hCapsItem` reads exactly those. Host→guest
  dispatch is `on_complete(session)` (`contract_data.zig:351`). A wasm guest
  can therefore provide `edit/completion` and NOTHING else with a payload —
  confirmed by `hProvideCompletion` hard-checking the capability name.

The in-process UI mesh (`gfx/view/ui_mesh.zig`) sidesteps all of this by NOT
crossing a membrane: its `ui_provider` variant (`container.zig:117`) is a raw
Zig `fn` pointer plus an opaque `ctx`, and the concrete argument type
(`StatuslineArgs`, `GutterLineArgs`, output `Seg`) is known to the adapter on
BOTH ends because both ends are the same process. Its own doc names itself
"the in-process transport's PREVIEW of D2's future schema-directed guest
payloads … deleted (or gains a schema-marshalled sibling) the day D2 ships."
That is the preview D2 makes real, and §5 names its demolition gate.

The machinery D2 must RHYME with (not duplicate) is the membrane contract:
`contract_data.zig` is a dependency-free pure-data table (`ValType = {i32,
u32}`, `Entry = {name, params, results, group, perm, head_gated, doc}`) that
compiles under `wasm32-freestanding` and is imported by BOTH the guest
(`src/guest/weft.zig`, comptime tripwire) and the host (`contract.zig`,
handler binding). Its stated limit is load-bearing for D2: "Zig 0.16 cannot
reify an `extern fn` declaration OR a struct-of-decls from a runtime-driven
comptime loop (no `@Type`, no `usingnamespace`)" — so the table VERIFIES
hand-written externs, it does not GENERATE them. D2's guest codegen story
(§3.3) is shaped entirely by that same wall.

The wire conventions D2 aligns to are `wire.zig`'s: length prefixes are
`u32` little-endian (`wire.encode`), and counts/lengths inside a body are
LEB128 varints (`putUv`/`getUv`). D2 reuses `putUv`/`getUv` verbatim and
adopts fixed-width little-endian for scalars — the "lean in to c" call: a
schema-directed payload is laid out like a packed C struct, not a
self-describing tag soup.

---

## 2. The schema language

### 2.1 Constructors (DECIDED set, with the two design fills marked)

A `Schema` is a tree. The constructor set is deliberately small (§5 F6 named
it: scalars, strings, arrays, structs, anchor, range):

```zig
// core/schema.zig — pure, no host deps, compiles wasm32-freestanding
// (RHYMES with contract_data.zig's dependency posture, on purpose: §3.2).
pub const Scalar = enum(u8) {
    bool, i32, i64, u32, u64, f32, f64,   // fixed-width LE, C-packed
};
pub const Schema = union(enum) {
    scalar: Scalar,
    str,                       // utf8, uv-length-framed, validated at the boundary
    bytes,                     // opaque, uv-length-framed (DESIGN: kept distinct
                               //   from str — a wasm blob / image is not utf8)
    array: *const Schema,      // uv count, then N elements
    @"struct": []const Field,  // fields in declared order, no padding
    optional: *const Schema,   // DESIGN: one presence byte (0/1), then the elem
    anchor,                    // schema-MARKED: a stemma EventAnchor (identity)
    range,                     // schema-MARKED: a StampedRange (version + [s,e))
    pub const Field = struct { name: []const u8, ty: *const Schema };
};
```

- **Scalars** are the seven above. Bools cross as one byte; ints/floats as
  fixed-width little-endian. No varint for scalars — a schema field's width is
  known from its type, so C-packing is both compact and zero-ambiguity. (uv is
  reserved for lengths/counts, where the value is a size and varint pays off —
  the `wire.zig` division, preserved.)
- **`str` / `bytes`** — both uv-length-framed. `str` is utf8-validated when
  the host decodes an untrusted (guest/remote) payload; `bytes` is not. Both
  are DECIDED present (F6 said "strings"; `bytes` is the DESIGN fill for the
  Tier-3 texture-rect / blob case rendering.md already anticipates).
- **`array`** — a uv count then that many elements of the element schema.
- **`struct`** — named fields, encoded in declaration order with no padding
  or field tags. The field name is METADATA (codegen, `explain`, evolution) —
  it does not cross the wire. This is what makes the encoding "compact like
  bespoke marshalling": the wire is just the field bytes back to back.
- **`optional`** (DESIGN) — one presence byte then the element if present.
  Needed for LSP-shaped payloads (a completion item's `documentation` is
  optional; today it crosses as an empty string, which conflates "absent"
  with "empty"). Cheap, and it is the pressure-relief valve for the
  union-shaped cases the language otherwise excludes (§7).
- **`anchor`** and **`range`** are the SCHEMA MARKS — the whole point of the
  fork. They are not free-form data; they are the two identity models already
  in the code, given a wire form (§4). AMENDED: they are the two standard
  registrations of the single `locator(P)` mark, which any protocol may join
  — see §4.1.

**Unions/enums are DELIBERATELY EXCLUDED** (DECIDED — F6's "deliberately
small"). This is not an oversight, and §7 states exactly where it bites. The
degenerate encodings until a client forces a real `variant` constructor:
a C-style tagged union is `@"struct"{ tag: u32, a: optional(A), b:
optional(B) }`; a closed enum is a `scalar.u32` whose meaning is documented
out of band (as `CompletionItem.kind` already is — "core does not interpret
it", `capability.zig:176`). The one place this hurts immediately is the
`capability.Payload` union itself — see §5, where it turns out NOT to need a
`variant` because it was never really one payload.

### 2.2 Value representation and carriage in the SlotDecl

The schema is a VALUE, carried three ways, all consistent:

1. **In-core, as a tree.** `SlotDecl.schema` changes from today's placeholder
   `SchemaRef = u32` (`container.zig:71`, "0 = no schema yet") to
   `schema: ?*const Schema`. The `SchemaRef` u32 is NOT deleted — it is
   RE-PURPOSED as the on-wire schema VERSION tag (§2.3): the tree is the
   local structure, the u32 is the version a peer/guest stamps a payload
   with so skew is detectable. (DESIGN: this reconciles the existing
   placeholder with the tree — one names structure, one names version.)

2. **On the wire / across the membrane, as a canonical blob.** The schema
   tree has ONE deterministic serialization — produced by running the
   marshaller (§3) over a fixed META-SCHEMA (the schema describing a
   `Schema`; self-hosting, the way `contract_data.zig` describes the contract
   the contract enforces). This blob is what a runtime-declared slot ships to
   the host, and what a remote head ships to a fresh peer.

3. **In config, as a JS literal** (DESIGN — the new `weft.slot` verb). Sealed
   manifest eval already turns `weft.*` calls into declaration structs
   (`manifest.zig`); `weft.slot` stages a `SlotDecl` whose schema is a nested
   object/array literal:

   ```js
   weft.slot("ui/badge", {
     shape: "query",
     composition: "ordered_union",
     schema: { struct: [
       { name: "text",  ty: "str" },
       { name: "count", ty: { scalar: "u32" } },
       { name: "where", ty: "anchor" },     // host restamps identity here
     ]},
   });
   ```

   The literal is pure data — no clock, no env, no I/O — so it passes the
   sealed-eval discipline (`manifest.zig` §"Sealed eval": the twelve `.config`
   imports are the only channel, and `hash()` is a pure length-framed content
   hash). The schema is therefore PART OF THE MANIFEST HASH and part of the
   approval diff: changing a slot's schema changes the approved artifact,
   exactly as changing a grant does. A `weft.slot` call stages a new
   `SlotDeclDecl` declaration type (rhyming with `StatusSegmentDecl` /
   `ManifestGrantDecl`, `manifest.zig:144`/`:184`), applied through the same
   `applyDecls` → `Container.declareSlot` path the UI mesh already uses.

### 2.3 Versioning and evolution

The precedent in this repo is `Conn.zig`'s `DocKind` trailing byte
(`Conn.zig:290`): a field added at the END of a wire payload, where an old
reader that stops before it is unaffected and a new reader treats "absent"
as the default (`if (cur.len > 0) … else .text`). The schema-level analogue,
DECIDED by that precedent:

- **A struct may only GAIN fields at the end.** Existing fields never change
  type, width, or order. Because every field is either fixed-width or
  uv-length-framed, a decoder built against version N is self-delimiting up
  to its last known field, so a payload from a version-N+1 producer decodes
  cleanly and its trailing extra fields are simply not read — the DocKind
  pattern, generalized from one byte to a field.
- **A field that may be absent for OLD producers is `optional`** — the
  presence byte lets a new consumer read new producers and old producers
  uniformly.
- **Renaming, removing, reordering, or retyping a field is a BREAKING change
  → a new slot name.** Not a schema bump. The slot name is the compatibility
  unit; the `SchemaRef` u32 version is only for detecting additive skew and
  refusing a payload that predates a field the consumer requires.
- **On the wire, a payload is prefixed with its producer's `SchemaRef`
  version** (a uv). A consumer newer than the payload applies trailing
  tolerance; a consumer OLDER than a breaking bump it can't satisfy REFUSES
  loudly (no silent third result — the plan's rule). For remote heads
  (rendering.md: scenes fire UI slots over the wire), a peer that has never
  seen a slot fetches its schema blob (§2.2 form 2) before decoding.

---

## 3. Marshalling, both directions

### 3.1 The wire encoding a schema directs

Given a schema and a source of field values, the encoding is a pre-order walk
emitting bytes with NO tags and NO padding:

- `scalar` → its fixed-width little-endian bytes (`std.mem.writeInt(..,
  .little)`, the `wire.encode` convention).
- `str` / `bytes` → `putUv(len)` then the bytes (reusing `wire.putUv`
  verbatim).
- `array` → `putUv(count)` then each element encoded in turn.
- `struct` → each field's encoding concatenated in declared order.
- `optional` → one byte `0` (absent, stop) or `1` (present, then the element).
- `anchor` → the EventAnchor wire form: `putUv(agent_name.len)`, agent bytes,
  `putUv(seq)`, one side byte (§4).
- `range` → the StampedRange wire form: `putUv(version.len)`, version bytes,
  `putUv(start)`, `putUv(end)` (§4).

Decoding is the mirror walk over a `*[]const u8` cursor, bounds-checked at
every step (a truncated or malicious payload traps, never over-reads — the
`wire.getUv` `error.Corrupt` discipline, extended). The decoder yields either
a typed view (guest codegen path) or a dynamic cursor API (`nextScalar`,
`enterArray`, `enterStruct` — the runtime interpreter path).

This is the "compact like bespoke marshalling" half: for `edit/completion`
the bytes are indistinguishable in size from today's hand-rolled
`wl_caps_item` stream. It is the "restampable like a tagged encoding" half
because the SCHEMA (not an inline tag) tells the host where the anchor/range
fields are (§4) — the tags live in the schema, once, not in every payload.

### 3.2 The host's table-driven interpreter — one implementation

The marshaller lives in **`core/schema.zig`**, a new module with the SAME
dependency posture as `contract_data.zig`: no wasmtime, no `wasm_host/*`, no
gfx — pure Zig over slices, so it compiles `wasm32-freestanding` and the
guest SDK imports the identical file (§3.3). Its surface:

```zig
pub fn encode(gpa, schema, src: Encoder)   ![]u8;   // src = a pull callback per field
pub fn decodeCursor(schema, bytes)          Cursor;  // dynamic walk (runtime slots)
pub fn walk(schema, bytes, visitor)         !void;   // the restamp/grant walk (§4)
pub fn canonicalizeSchema(gpa, schema)      ![]u8;   // schema → its own blob (meta-schema)
```

**How it avoids becoming a SECOND contract system beside
`contract_data.zig`** — stated at the function level, because "rhymes with"
is not a design:

- `contract_data.zig` governs the FIXED membrane surface: which `wl_*` calls
  exist, their wasm arity (`params`/`results`), their perm gate, their
  head-gating. That set is CLOSED and comptime-checked. It stays the sole
  authority on the call surface.
- `schema.zig` governs the CONTENT of DYNAMIC payload bytes that ride
  through a SMALL, FIXED set of NEW generic `wl_*` calls. Those calls are
  themselves `contract_data.imports` entries (below) — so they are governed
  by the existing contract, comptime-checked like everything else. `schema.zig`
  never declares a call; `contract_data.zig` never inspects a payload's
  structure. They compose along one seam: the generic calls carry `(SchemaRef
  version, ptr, len)`; `contract_data` checks the call's arity, `schema.zig`
  interprets the `(ptr,len)` bytes against the slot's schema.
- The new `contract_data.imports` entries (DESIGN, ~4, in a new `slot`
  group), replacing the completion-specific `wl_caps_*` on the general path:
  - `wl_slot_declare(name_ptr, name_len, schema_ptr, schema_len)` — a guest
    declares a slot at runtime; host decodes the schema blob via
    `schema.canonicalizeSchema`'s inverse and calls `Container.declareSlot`.
  - `wl_slot_bind(name_ptr, name_len, predicate_ptr, predicate_len, tier,
    priority)` — bind a provider; the predicate itself is a schema-encoded
    value (facts.Predicate has a schema too — self-hosting again).
  - `wl_payload_push(session, version, ptr, len)` — the generic successor to
    `wl_caps_item`+`wl_caps_commit`: one schema-encoded payload for a session.
    Host decodes against the slot's schema, restamps (§4), and hands it to the
    same `caps.push` / feed / action machinery unchanged.
  - `wl_payload_read(session, ptr, cap)` — host→guest, the generic successor
    to the request-side accessors, filling a guest scratch buffer with a
    schema-encoded request payload.

  These four are added to `contract_data.imports` exactly like any other
  entry (bump `expected_import_count`, mirror the extern in `weft.zig`,
  comptime-verified). The `wl_caps_*` completion-specific imports are NOT
  deleted on day one — they coexist until the completion path migrates (§5),
  then are removed (one-implementation doctrine).

The host is table-driven in the literal sense: for a runtime-declared slot it
holds only the schema tree (from `wl_slot_declare`), and `schema.walk` /
`schema.decodeCursor` interpret bytes against it with no per-slot code. This
is the ONE implementation the plan demands — the same `schema.walk` serves
caps payloads, feed frames, action batches, UI-mesh segments, and remote-head
scene payloads.

### 3.3 The guest SDK codegen story

DECIDED by F6 that guests MAY codegen; DESIGN below is HOW, shaped by the Zig
comptime wall `contract_data.zig` already documents.

- **What is generated:** for a slot whose schema is known at the guest's
  BUILD time, a codegen tool reads the schema VALUE (the JS literal, or the
  canonical blob) and emits source — typed structs plus a specialized
  `encode`/`decode` pair — in the guest's language (`.zig`, `.js`, `.ts`).
  The generated code is what plugin authors call ergonomically
  (`badge.encode(.{ .text = "!", .count = 3, .where = anchor })`), the same
  way `weft.zig`'s hand-written wrappers wrap the raw externs today.
- **From what, when:** from the schema value, at the guest's build step
  (out of band — a `build.zig` codegen invocation, mirroring how the embedded
  guest wasm is produced). NOT at comptime from a runtime schema: the wall
  in `contract_data.zig`'s doc ("Zig 0.16 cannot reify a decl from a
  runtime-driven comptime loop") applies in full — a guest cannot synthesize
  typed accessors at comptime from a schema it received at runtime.
- **The runtime fallback for slots discovered at RUNTIME:** a guest consuming
  a THIRD-PARTY slot it did not know at build time uses the SAME
  `schema.decodeCursor` runtime interpreter the host uses (that is why
  `schema.zig` compiles `wasm32-freestanding`). Ergonomics degrade to a
  dynamic cursor (`cur.field("count").u32()`), but it works with zero
  codegen and zero core recompile. This exactly mirrors `contract.zig`'s own
  split — comptime-verified typed helpers where the shape is known
  (`callRequiredExport`), a runtime walk where it isn't.

---

## 4. Restamping

The fork's keystone: the host restamps versions inside payloads it doesn't
otherwise understand, because anchors/ranges are SCHEMA-MARKED. The subtlety
that must be told straight is that there are TWO marks because there are TWO
identity models already in the code, and they restamp DIFFERENTLY:

- **`range` = `StampedRange`** (`position.zig:96`): a positional `[start,end)`
  plus a version TOKEN. Today `capability.zig`'s `restamp` (`:734`) hand-walks
  the union and, for `locations` and `symbols`, overwrites `range._version`
  with the session version. "Restamp a range" = rewrite the version token.
  This is the version-stamping invariant, and it stays core-enforced: the
  host, walking the payload by schema, rewrites every `range` field's version
  to the fired version — the provider's claimed version is never trusted
  (`capability.zig`'s existing rule: "the stamp is enforced by the core, not
  trusted from the provider").
- **`anchor` = `EventAnchor`** (`grants.zig:122`, `= stemma.TextDoc.Event
  Anchor`): an `(agent, seq, side)` IDENTITY, stable under concurrent edits.
  An anchor is NOT restamped — it is RESOLVED against the live document
  (`stemma.resolveAnchors`), and it COLLAPSES (traps) if its character was
  deleted or compacted. This is the identity model W4's `doc_region` grants
  use.

So the schema mark selects the operation:

```
schema.walk(schema, bytes, .{
    .on_range  = |field| host rewrites field.version := fired_version,   // caps restamp
    .on_anchor = |field| host records the anchor for resolution / grant check,
})
```

Generalizing `capability.zig:734`'s three-tag `switch` into one
`schema.walk` is the mechanical heart of the migration: `restamp`,
`dupePayload`, and `Result.deinit` (the three hand-walks) all collapse into
schema-directed walks (`walk` for restamp, a `dup`-visitor for the copy, a
`free`-visitor for teardown). Three bespoke switches → one interpreter, per
the one-implementation doctrine.

**Interaction with grants (W4).** W4's `command.Context.checkDocRegion` is the
single chokepoint that admits or traps an edit against an identity-anchored
`doc_region` grant (`grants.zig`, `DocRegion{doc_id, start: EventAnchor, end:
EventAnchor}`). Today an edit's region is passed explicitly; a schema-carried
payload with `anchor`-marked fields makes the connection direct and DESIGN
says reuse the same walk:

- When an action/edit payload crosses with `anchor`-marked fields, the host
  runs `schema.walk` ONCE, collecting the anchor fields, and feeds each to
  `checkDocRegion` against the caller's grant. The `.on_anchor` visitor and
  the grant check are the same walk — the host does not walk the payload once
  to restamp and again to grant-check.
- This CONSOLIDATES two mechanisms that are separate today (`caps.restamp`
  in `capability.zig`; `checkDocRegion` in `command.Context`). Named plainly
  so it isn't smuggled: D2 gives W4 its enforcement walk for free, and W4
  gives D2 the reason anchors are a first-class mark rather than opaque bytes.
  A schema whose anchor fields all resolve inside the grant admits; one that
  resolves outside traps (`error.OutOfLimit`); one whose anchor collapsed
  traps (`error.Collapsed`) — the exact three outcomes
  `wasm_abi/runtime.zig`'s `trapDocRegion` already distinguishes.

### 4.1 The locator mark

Two marks were one mark too few. `anchor` and `range` are the two identity
models that happened to exist when D2 was written, and freezing them into the
constructor set says the payload language knows every identity anyone will
ever locate — which is false the moment a plugin carries a commit OID, a
snapshot-scoped hunk, a filesystem entry, or a field path. The alternative
those payloads fall back to is `str`/`bytes`, which loses the walk entirely:
core cannot restamp, grant-check, or even skip what it cannot see.

So the mark is ONE constructor, `locator(P)`, naming a protocol. The
protocol's registration carries what the mark used to hard-code:

```zig
Protocol {
    name: []const u8,          // the identity, and the version unit
    shape: *const Schema,      // the payload's wire form
    policy: enum { observation_restamp, effect_opaque },
}
```

`shape` is what makes an unfamiliar locator crossable: a walker that knows
nothing about `plugin.git.oid` still knows how many bytes it occupies, so a
payload carrying it stays walkable, skippable, and restampable around it.
Nothing else changes about the walk — it is still one traversal over shape
alone.

Registration is the trust boundary: an unregistered protocol name is REFUSED
(`error.UnknownProtocol`), at declaration, at parse, at encode, and at the
walk. There is no "carry it as opaque bytes" third result, for the same
reason §2.3 has no silent skew result — a locator core cannot describe is a
locator core cannot enforce a policy on.

### 4.2 Restamp for observations, refuse for effects

The policy field is the split §4 already implies but never states. The host
restamps an OBSERVATION — a diagnostic's span, a symbol's range, anything a
provider reports about a document it does not own — because the provider's
claimed version is not evidence, and a stamp taken from the fired session is.
That is anti-spoofing, and it is safe precisely because an observation is
inert: rewriting the stamp on a report changes nothing but the report's
honesty.

The host never rewrites an EFFECT locator. An edit's anchor, a hunk to apply,
a file to rename — those name what the caller will change, and a host that
silently re-stamped them would forge agreement to a target the caller never
chose. A stale effect locator has exactly two honest answers, and both belong
to the caller: refuse (`error.Collapsed` / `error.OutOfLimit`, the outcomes
§4's grant walk already produces), or re-resolve against the live state and
ask again. Both are the caller's call because only the caller knows whether
the intent survives the drift.

`anchor` and `range` become the two standard registrations of this rule:
`std.text.anchor` is effect-path (an anchor is resolved, never rewritten) and
`std.text.range` is observation-path (its version token is exactly what the
host stamps). Their payload bytes and their single-byte canonical tags are
unchanged — this is an additive generalization, and nothing already on the
wire re-encodes.

### 4.3 Protocol names are the major version

§2.3 makes the slot name the compatibility unit for payloads; the protocol
name is the same unit for identity. A protocol never changes its shape or its
policy — changing either produces a new name (`@N` where a version suffix
reads better than a new noun). Additive evolution inside a protocol's payload
follows §2.3's struct rule unchanged.

Content-derived digests are deliberately NOT the identity. A digest is a
negotiation instrument, not a name: it answers "do we hold the same bytes for
this thing?", which only matters where two heads must agree before decoding —
the collaboration membrane, where a peer fetches an unknown slot's schema
blob (§2.2 form 2). Inside one head, a name resolves through the registry and
a digest would buy nothing but a rebuild-sensitive identity.

---

## 5. Migration

### 5.1 The closed union, member by member

Each `capability.Payload` member maps to a per-SLOT schema. The union
DISSOLVES — and, crucially, needs NO `variant` constructor — because its
members were never one payload: they are five (seven, by Kind) DISTINCT
capability NAMES (`Kind.capabilityName`, `capability.zig:137`) that happen to
share one session struct. Give each slot its own schema and the union is
redundant.

| union member (`capability.zig`) | slot(s) | schema |
|---|---|---|
| `completion: []CompletionItem` | `edit/completion` | `array(struct{ text:str, label:str, detail:str, documentation:optional(str), kind:u32, rank:i32 })` |
| `text: []u8` (hover) | `edit/hover` | `str` |
| `locations: []Location` | `edit/definition`, `edit/references` | `array(struct{ uri:str, range:range })` |
| `symbols: []Symbol` | `edit/symbols-document` | `array(struct{ name:str, kind:u32, range:range, depth:u32 })` |
| `edits: []Replacement` | `edit/format`, `edit/rename` | `array(struct{ start:u32, end:u32, text:str })` |

Two honest notes:

- `CompletionItem.documentation` becomes `optional(str)` — a strict
  improvement over today's empty-string-means-absent conflation. Additive and
  safe (§2.3): old producers omit it, `optional`'s presence byte handles it.
- `Replacement.start/end` (`capability.zig:193`) are plain offsets "against
  the result's version", NOT a `StampedRange` — and `restamp` deliberately
  does NOT touch them. The faithful migration keeps them `scalar.u32` and lets
  the payload's single fired version (carried once, out of the field walk)
  govern them — ZERO behavior change. Promoting each to a `range` is the
  cleaner form but a real semantic change; deferred, noted, not smuggled.

### 5.2 ui_provider (the preview) migrated first, on paper

The UI mesh is the first client because it already exists and its slots are
already declared (`ui_mesh.zig`'s `declareSlots`), merely with `schema = 0`.
On paper:

- `ui/statusline-seg` gains a real schema: the decoded form of `Seg`
  (`ui_mesh.zig:59`) — `struct{ text:str, role:u32, fg_override:optional(...),
  bg_override:optional(...), align_right:bool, gap_after:u32 }`. `StatuslineArgs`
  (the request side) gains the mirror schema.
- The in-process default providers keep their raw-fn transport — this is a
  LEGITIMATE optimization, the exact `abi.zig`/`weft.zig` split rendering.md
  describes (in-process skips serialization; the membrane is the contract,
  the transport is per-client). But the private `Args`/`Seg` types are now
  DEFINED AS the schema's decoded form, so an out-of-process guest producing
  schema bytes and an in-process provider filling the struct agree by
  construction.

### 5.3 The demolition gate

The one-implementation doctrine forbids the closed union and the schema path
coexisting indefinitely. Two named gates:

- **Primary — the `caps.push` schema cutover** (demolishes
  `capability.Payload`). Trigger: when all seven `Kind`s resolve through
  schema-carrying slots AND `caps.push` takes `(SchemaRef version, bytes)`
  instead of a `Payload` variant. At that point `dupePayload`, `restamp`,
  and `Result.deinit`'s three switches are replaced by schema walks and the
  `Payload` union is deleted, along with the completion-specific `wl_caps_*`
  imports (removed from `contract_data.imports`, count bumped down). This is
  W5/W6 work; the gate is falsifiable: `grep 'Payload'` in `capability.zig`
  returns nothing, and `wl_caps_item` is gone from the contract.
- **Secondary — UI-slot schema adoption** (demolishes the `ui_provider`
  preview's status AS a preview). Trigger: P4 (UI-as-plugin, rendering.md)
  landing on D2 — the day a GUEST binds a `ui/*` slot through schema bytes.
  `ui_provider` survives ONLY as the in-process transport of a
  schema-carrying slot (like `abi.zig`), never again as a slot's ONLY
  crossing story. Its `container.zig:117` doc's promise ("deleted or gains a
  schema-marshalled sibling the day D2 ships") is discharged by the "gains a
  sibling" arm, with the sibling being the generic `wl_payload_push` path.

Until the primary gate fires, the two paths coexist by DESIGN under a stated
demolition date (W6), which is the plan's federate-first / demolish-on-a-clock
discipline (F1), applied to payloads.

---

## 6. What third-party UI becomes able to do — the §7 stake, made concrete

Today (the wall): a third-party wasm plugin can return exactly one payload
shape, completion items, through `wl_caps_item`. It CANNOT declare a novel UI
slot with a novel result, because `Payload` is closed and no generic push
exists. §7 item 2's question — "is third-party UI real, or is the mesh
first-party-only with extra steps?" — answers "extra steps" without D2.

With D2, the worked example, no core recompile:

1. **Plugin A (a CI-status plugin) declares a novel slot.** In its config or
   `describe()`: `weft.slot("ui/badge", { shape:"query", composition:
   "ordered_union", schema:{ struct:[ {name:"text",ty:"str"},
   {name:"count",ty:{scalar:"u32"}}, {name:"where",ty:"anchor"} ]}})`. The
   host `wl_slot_declare`s it into the Container; the schema is now a value
   the host holds and can marshal, restamp (`where` is anchor-marked, §4),
   and serialize to a peer.
2. **Plugin A binds a provider** with `wl_slot_bind`, emitting badge payloads
   via `wl_payload_push` — schema-encoded bytes, decoded by `schema.zig`
   against the slot's schema. Core never had a `badge` type; it doesn't need
   one.
3. **Plugin B (a statusline theme) consumes it.** It fires `ui/badge`
   (`Container.eligible`, exactly as `ui_mesh.zig`'s `fireStatusline` does
   today), decodes each result with `schema.decodeCursor` (runtime path,
   §3.3 — B did not know `badge` at build time), and renders the text + count
   as a `Seg`. The `where` anchor rides through, restamped by the host so B's
   render lands on the right line even after concurrent edits.
4. **A remote head sees it too:** the scene fires over the wire (rendering.md);
   the badge payload is schema-encoded bytes with a `SchemaRef` version prefix;
   a peer that lacks the schema fetches its blob (§2.2) and decodes. Metric-
   free scene + schema-typed payload = wire-safe by construction.

No step recompiles core. That is third-party UI being REAL. The schema is the
wire format's type system, which is precisely why rendering.md's "scenes are
wire-safe" and D2 are one design.

---

## 7. Boundaries, told straight

**What schema-directed marshalling does NOT cover.**

- **Behavior / callbacks.** A schema marshals DATA, never function pointers.
  Host→guest DISPATCH (the `on_complete`/`on_menu`/… entrypoints,
  `contract_data.exports`) stays call-based and stays governed by
  `contract_data.zig`, not by schemas. A slot whose "result" is really "a
  thing you call back into" is not a payload — it is a session (feed/action
  shape). D2 types the data that crosses; it does not let a guest ship a
  closure. (The `container.zig` `ui_provider` raw-fn variant is exactly a
  closure, and that is why it is an in-process-only optimization, never the
  crossing story.)
- **Streaming / backpressure.** A schema describes ONE payload. A feed
  streams MANY, each schema-shaped, but the streaming itself — priority
  classes, latest-wins coalescing — stays `wire.zig`'s `Outbox` job. Schemas
  type each frame; they do not sequence frames.
- **Graph structure (yet).** A self-referential schema (a tree node whose
  children are nodes) is not expressible with a flat `struct`/`array` — see
  below. W5's transcript ships as a projected TEXT payload, not a recursive
  schema; a recursive/`ref` constructor is deferred until a structural client
  forces it.

**Where the small language feels cramped first** (the honest frontier, in
the order it will bite):

1. **Unions / variants.** LSP is full of them (`MarkupContent | string`;
   completion's `textEdit | insertText`; the media-player example's command
   variants). The `struct{tag,optional…}` degenerate encoding (§2.1) is
   ugly and lets an author express an invalid combination (two arms present).
   The FIRST real client to hit this — plausibly the LSP plugin's hover
   migration — is the forcing function for a `variant` constructor. Named as
   the most likely first extension.
2. **Recursion / references.** The graph substrate (W5/W7) wants a node
   schema that contains its own children. Flat structs can't; a `ref`/named-
   schema constructor is the fix, deferred to its client.
3. **Dynamic-key maps.** A config blob or a JSON object with arbitrary keys
   is neither `struct` (keys not known) nor `array`. `array(struct{key:str,
   value:…})` is the workaround; a real `map` constructor waits for a client.

**The cost of the host walk** (vs today's bespoke paths).

- Today's `wl_caps_item` does one `readMemory` per string field and no schema
  traversal. Schema-directed decode adds a walk of the schema TREE per payload
  plus a bounds check per field. For `edit/completion` (an array of six-field
  structs × N items) the per-field work is the SAME hand-loop count; the new
  cost is traversing the (tiny, cache-hot) schema tree alongside it — small,
  but not zero, and it is paid on the hottest, largest payload in the system.
- The genuinely new per-payload cost is the RESTAMP/ANCHOR walk running on
  EVERY payload with a marked field, where today only `locations`/`symbols`
  are walked and only to rewrite `_version`. For anchor-heavy payloads the
  walk now also does identity resolution (`resolveAnchors`) — real work,
  though it is work W4's grant check would do anyway (§4's consolidation
  makes it one walk, not two).
- **The latency-instrument category to watch:** W0a built the dispatch-latency
  harness (C10, the falsifiable-gate instrument). D2 adds a **payload-marshal
  category** to it — encode + decode + restamp/anchor time per slot fire,
  measured against the bespoke `wl_caps_item` baseline on the completion path
  (the hot, large payload). If schema-directed completion regresses that
  baseline measurably, the encoding or the walk needs a specialization pass
  before the primary demolition gate (§5.3) fires — the plan's rule that a
  gate without a baseline is unfalsifiable, applied here.

---

## 8. What resists the decided design (contradictions, told straight)

- **`capability.Payload` is a `union`, and the schema language excludes
  unions.** Surface contradiction, resolved in §5.1: it was never one
  payload — it is per-Kind slots sharing a struct. The union dissolves into
  per-slot schemas and needs no `variant`. But this means the FIRST place the
  missing `variant` bites is not the union itself — it is a single slot's
  result being genuinely sum-typed (LSP hover, §7). The language buys
  migration cheaply and defers the hard case; that is a real, bounded debt.
- **Two identity models wearing one fork's name.** F6 says "anchors/ranges
  are schema-marked fields." The code has BOTH `StampedRange` (version-token,
  restamp = rewrite) AND `EventAnchor` (identity, resolve = walk + trap).
  They are not interchangeable; §4 keeps them as two marks with two
  operations. A design that treated "restamp" as one operation would be
  wrong on one of them.
- **`Replacement` offsets aren't stamped.** The migration keeps them scalars
  (§5.1) — faithful but it means the format/rename path has a THIRD version
  convention (whole-payload version) beside `range` and `anchor`. Honest, and
  flagged; the clean unification (promote to `range`) is a deferred semantic
  change, not smuggled into the port.
- **The Zig comptime wall constrains "guests may codegen."** F6's codegen is
  real only as an out-of-band build step or a runtime interpreter (§3.3);
  it is NOT comptime synthesis from a runtime schema, because
  `contract_data.zig` already proves Zig 0.16 can't do that. The fork's
  "codegen typed bindings" is honored in the build-time and runtime-fallback
  arms, not in a comptime arm that cannot exist.

See contextual-workspace-architecture.md (typed protocols and negotiated
schemas), rendering.md (scenes wire-safe, the UI mesh, `ui_provider` as
in-process transport),
`core/capability.zig` (the closed union + the three hand-walks D2 collapses),
`core/membrane/contract_data.zig` (the machinery D2 rhymes with and the
comptime wall it obeys), `core/container.zig` (`SlotDecl`/`SchemaRef`/
`ui_provider`), `core/position.zig` + `core/grants.zig` (the two identity
models the marks name), `core/wire.zig` (the encoding conventions D2 reuses),
`core/manifest.zig` (sealed eval, the config-surface pattern `weft.slot`
joins).
