//! Pick — the fuzzy-select primitive. One core mechanism, many uses:
//! the command palette is `pick-commands` over the registry's names, a
//! config can `weft.pick` its own items with a Fennel callback. State
//! is plain data the view renders (prompt, query, filtered items,
//! selection); interaction is ordinary commands bound in the "pick"
//! keymap mode, which declares `pick-input` as its commit command — the
//! picker adds no new input machinery at all.
//!
//! Entries carry an optional docstring the view renders beside the
//! text (the palette shows command summaries). Filtering runs a
//! selectable completion `Style` (default ORDERLESS — space-split tokens,
//! each a case-insensitive subsequence, matched in any order; also flex,
//! substring, prefix), ranked by word-boundary hits, then span tightness,
//! then earliest match, then FRECENCY — what you accepted recently under
//! this prompt floats up, so an empty-query palette is your recent list.
//! A sticky NARROWING filter (`pick-narrow`) pre-restricts the set, the
//! live query ranking within it. Recency is an ordinal use counter, not a
//! clock. Tab completes the query (common prefix of the matches, else
//! the selection).
//!
//! This file is the public facade; the implementation lives in `pick/`:
//! - `match.zig`  — the pure matcher (styles + scoring functions).
//! - `Pool.zig`   — the append-only candidate pool + its bulk `rank`.
//! - `types.zig`  — the configuration/callback value types.
//! - `Pick.zig`   — the `Pick` state machine, commands, and `install`.

const match = @import("pick/match.zig");
const types = @import("pick/types.zig");

/// How the query filters candidates.
pub const Style = match.Style;

/// The append-only, columnar candidate pool + its bulk `rank`.
pub const Pool = @import("pick/Pool.zig");

/// The accept callback handed to `open`.
pub const Acceptor = types.Acceptor;
/// Match evidence captured with an accepted candidate.
pub const Match = types.Match;
/// An accepted candidate: identity, presentation, query, and match facts.
pub const Candidate = types.Candidate;
/// A pick's terminal accepted/cancelled event.
pub const Outcome = types.Outcome;
/// An async candidate producer driven by the picker's per-frame `tick`.
pub const Source = types.Source;
/// Options for `openWith` (free-text accept, an async source, a style).
pub const Options = types.Options;
/// One selectable item: matchable text plus a display-only docstring.
pub const Entry = types.Entry;

/// The fuzzy-select state machine (prompt, query, filtered items, selection).
pub const Pick = @import("pick/Pick.zig");
/// Register the pick commands + the "pick" mode bindings.
pub const install = Pick.install;
/// Replace the item set of a live pick, preserving query and selection.
pub const refresh = Pick.refresh;

// Pull every implementation file into the test graph so `zig build test`
// discovers the matcher, pool, and state tests through this facade.
comptime {
    _ = match;
    _ = Pool;
    _ = types;
    _ = Pick;
}
