# Proposal: hole-bearing bases in stemma TextDoc (upstream)

Rope-level holes exist (`fromUnrealized`/`realize`) and weft's wire v1
uses them for read-only partial checkout of large remote files. What
partial checkout of an *editable, collaborative* document needs is one
level deeper: a TextDoc whose compacted base is partially unrealized —
reserved event-id ranges for base characters so anchors and concurrent
ops in unfetched regions stay well-defined, `realize`-style base
materialization that never counts as an edit, and merge behavior that
treats ops adjacent to holes as legal. weft's chunk-table skeleton
(lengths + lazily-learned hashes) supplies exactly the base metadata
such a TextDoc would need. Until then, huge remote files open as a
viewer (holey rope + range requests); normal files collaborate fully.
