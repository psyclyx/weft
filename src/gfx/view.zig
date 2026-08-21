//! view — the View package root: the `View` type plus its satellites.
//!
//! `View` (Editor state → snail shapes) is the dominant type and lives in
//! its own struct file `view/View.zig`; this root is a thin, curated
//! re-export so importers name `view.View` / `view.Hud` / `view.Theme` /
//! `view.Built` (and the render submodules name `view.Run` / `view.Rect`)
//! unchanged. The frame chrome + caret + markdown-styling + tab data live
//! in `view/hud.zig`; the palette in `view/Theme.zig`; the render routines
//! (statusline/popup/decoration/linelayout/render) are free-function
//! namespaces over `*View` in their own files.

/// The main type: Editor state → snail shapes. Its associated output
/// vocabulary (`Built`, `Run`, `Rect`) hangs off it as public decls.
pub const View = @import("view/View.zig");
pub const Built = View.Built;
pub const Run = View.Run;
pub const Rect = View.Rect;

/// The frame's non-buffer chrome + caret shape + markdown-styling handle +
/// tab datum, from `view/hud.zig`.
const hud_mod = @import("view/hud.zig");
pub const Hud = hud_mod.Hud;
pub const CursorStyle = hud_mod.CursorStyle;
pub const MdInline = hud_mod.MdInline;
pub const Tab = hud_mod.Tab;

/// The view's color palette (data + role→color lookups), from `view/Theme.zig`.
pub const Theme = @import("view/Theme.zig");

/// The caret/corner/center overlay renderer — re-exported so a caller outside
/// this package (the popup-layout e2e gate) can drive `popup.pickSurface`/
/// `popup.hoverSurface` → `popup.layoutCaretSurface` directly, over a live
/// `Pick`, without hand-building a `core.surface.Surface`.
pub const popup = @import("view/popup.zig");

// ── Tests ──

test {
    // Pull the package's files' own tests into this file's test set (it is
    // the one referenced by src/tests.zig, so re-exports alone would not
    // guarantee their discovery).
    _ = View;
    _ = @import("view/Theme.zig");
    _ = @import("view/hud.zig");
    _ = @import("view/statusline.zig");
    _ = @import("view/popup.zig");
    _ = @import("view/decoration.zig");
    _ = @import("view/linelayout.zig");
    _ = @import("view/render.zig");
}
