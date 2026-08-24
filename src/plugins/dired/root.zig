//! Plugin-facing dired model facade.
//!
//! Implementation and focused model tests live in `model.zig`; this root
//! intentionally exports only the stable plugin contract and keeps the
//! dedicated named-module build entrypoint small.

const std = @import("std");

pub const model = @import("weft_dired_model");
pub const projection = @import("weft_dired_projection");
pub const actions = @import("weft_dired_actions");
pub const session = @import("weft_dired_session");

pub const Model = model.Model;
pub const NodeId = model.NodeId;
pub const Pending = model.Pending;
pub const Conflict = model.Conflict;
pub const SnapshotEntry = model.SnapshotEntry;
pub const Snapshot = model.Snapshot;
pub const Observation = model.Observation;
pub const Draft = model.Draft;
pub const Row = model.Row;
pub const OwnedPlan = model.OwnedPlan;
pub const PastePlacement = model.PastePlacement;
pub const PasteAnchor = model.PasteAnchor;

pub const max_transfer_payload = model.max_transfer_payload;
pub const max_transfer_records = model.max_transfer_records;
pub const max_transfer_name = model.max_transfer_name;
pub const max_transfer_revision = model.max_transfer_revision;

pub const FieldBinding = projection.FieldBinding;
pub const OwnedScene = projection.OwnedScene;
pub const project = projection.project;
pub const metadata_column = projection.metadata_column;
pub const name_column = projection.name_column;
pub const original_column = projection.original_column;
pub const rowNodeId = projection.rowNodeId;
pub const modelRowId = projection.modelRowId;

pub const ActionController = actions.Controller;
pub const ActionError = actions.Error;
pub const Plugin = session.Plugin;
pub const Session = session.Session;

test {
    std.testing.refAllDecls(@This());
}
