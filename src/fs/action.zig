//! Open action names for filesystem-shaped semantic tools.
//!
//! These are interoperability data, not built-in commands or behavior. A
//! directory editor, archive browser, remote workspace, or another plugin may
//! advertise them; config declares matching command trampolines, while the
//! owning view provider decides what they mean for its draft.

pub const permissions_edit = "fs.permissions.edit";
pub const entry_create_file = "fs.entry.create-file";
pub const entry_create_directory = "fs.entry.create-directory";
