//! Portable plugin-facing dired facade.
//!
//! This root deliberately contains only the host-independent model,
//! projection, and action contracts. Host integration is exposed separately
//! by `host.zig`; keeping that edge out of this facade makes it impossible for
//! portable dired users to acquire runtime registries accidentally.

const std = @import("std");

pub const model = @import("weft_dired_model");
pub const projection = @import("weft_dired_projection");
pub const actions = @import("weft_dired_actions");

pub const Model = model.Model;
pub const NodeId = model.NodeId;
pub const Pending = model.Pending;
pub const Conflict = model.Conflict;
pub const SnapshotEntry = model.SnapshotEntry;
pub const Snapshot = model.Snapshot;
pub const Observation = model.Observation;
pub const Draft = model.Draft;
pub const Row = model.Row;
pub const EntryCapture = model.EntryCapture;
pub const OwnedPlan = model.OwnedPlan;
pub const PastePlacement = model.PastePlacement;
pub const PasteAnchor = model.PasteAnchor;

pub const max_transfer_payload = model.max_transfer_payload;
pub const max_transfer_records = model.max_transfer_records;
pub const max_transfer_name = model.max_transfer_name;
pub const max_transfer_revision = model.max_transfer_revision;
pub const entry_media_type = model.entry_media_type;
pub const entry_schema_current = model.entry_schema_current;
pub const entry_schema_legacy = model.entry_schema_legacy;
pub const isEntryTransferSchema = model.isEntryTransferSchema;
pub const encodeEntryTransfer = model.encodeEntryTransfer;
pub const decodeEntryTransfer = model.decodeEntryTransfer;

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

test {
    std.testing.refAllDecls(@This());
}
