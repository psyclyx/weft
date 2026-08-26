//! Borrowed semantic scene inputs for one frame. The application resolves
//! generation-checked handles before constructing these values; the renderer
//! sees only a scene root, stable focus identity, and generic field services.

const semantic = @import("weft_semantic");
const view_runtime = @import("weft_view_runtime");

pub const Document = struct {
    view: semantic.view.Ref,
    root: *const semantic.scene.Node,
    /// Buffer-owned presentation label. Providers publish meaning; the shell
    /// supplies the buffer name without baking file-browser chrome into them.
    title: []const u8 = &.{},
    focused: ?semantic.scene.NodeId = null,
    fields: *const view_runtime.field.Registry,
};

pub const Overlay = struct {
    document: Document,
    /// Opaque plugin-authored hint interpreted by the selected presenter.
    /// The bundled presenter recognizes a few conventional hints and gives
    /// unknown values the dialog default; core does not enumerate them.
    presentation: []const u8 = &.{},
};
