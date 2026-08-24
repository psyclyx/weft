//! Borrowed semantic scene inputs for one frame. The application resolves
//! generation-checked handles before constructing these values; the renderer
//! sees only a scene root, stable focus identity, and generic field services.

const kernel = @import("weft_kernel");
const view_runtime = @import("weft_view_runtime");

pub const Document = struct {
    view: kernel.view.Ref,
    root: *const kernel.scene.Node,
    focused: ?kernel.scene.NodeId = null,
    fields: *const view_runtime.field.Registry,
};

pub const Overlay = struct {
    document: Document,
    /// Opaque plugin-authored hint interpreted by the selected presenter.
    /// The bundled presenter recognizes a few conventional hints and gives
    /// unknown values the dialog default; core does not enumerate them.
    presentation: []const u8 = &.{},
};
