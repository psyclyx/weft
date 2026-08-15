# Capability profile v1 (ABI)

A capability is a registry entry: namespaced **name**, **schema version**,
**shape**, **composition semantics**. Providers register implementations
with a scope predicate (file-extension matcher or match-all), a
**placement** (`local` | `host`), a **latency class** (`instant` | `fast`
| `slow`), and a priority. Consumers address capability *names* only.

**Shapes** (exactly three): **query** — request/response against a
snapshot version; consumer API is a race (fire all matching providers,
results land incrementally with provider identity + latency; a dead
provider degrades the set, never hangs). **feed** — continuous
publication of version-stamped annotations into a named layer the
provider owns (layer scopes: `local` | `host` | `replicated`; feeds are
droppable by definition). **action** — provider returns a proposed
replacement batch against a stated version as *data*; the consumer
applies it through the ordinary edit path where it merges like any
peer's ops.

**Version stamping (core-enforced).** Every result and annotation
carries the version token it was computed against. Positions cross the
ABI only as stamped offsets; the consumer obtains a usable offset
exclusively through `position.rebase` (maps through the commit log) or
receives `null` — rebase or discard, no third option, no raw offsets.

## Profile

| name | shape | composition | params → result |
|---|---|---|---|
| `edit/completion` | query | merge-ranked | stamped position, word prefix → items `{text, label?, detail?, rank}` |
| `edit/hover` | query | first-wins-by-priority | stamped position → `{contents}` (plain text v1) |
| `edit/definition` | query | first-wins-by-priority | stamped position → locations `{uri?, stamped range}` |
| `edit/references` | query | all (union) | stamped position → locations |
| `edit/diagnostics` | feed | union-tagged (by provider) | — → layer spans `{stamped range, severity 1–4, message}` |
| `edit/highlight` | feed | first-wins-by-priority | — → layer bulk paint `{stamped range, class-per-byte}` |
| `edit/format` | action | first-wins-by-priority | stamped range? → replacements vs version |
| `edit/rename` | action | first-wins-by-priority | stamped position, new name → replacements vs version |
| `edit/symbols-document` | query | first-wins-by-priority | — → symbols `{name, kind, stamped range, depth}` |

Schemas are deliberately smaller than LSP's; the LSP plugin translates
at its boundary and its wire types never escape it. `rank` is a
provider-local ordering hint; merge-ranked interleaves by (latency
class, priority, rank). Composition is implemented by the core's
session collectors, not by consumers.

Drift note (prompt vs shipped MVP): the MVP as built had no annotation
layer machinery; `core/layers.zig` is introduced alongside this profile
as the feed substrate (sparse anchored spans + dense stamped bulk
regions, scope-tagged). `replicated`/`host` scopes gain wire meaning in
phase-2 workstream 4; until then they are routing metadata.
