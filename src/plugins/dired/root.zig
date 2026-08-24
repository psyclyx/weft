//! Plugin-facing dired model facade.
//!
//! Implementation and focused model tests live in `model.zig`; this root
//! intentionally exports only the stable plugin contract and keeps the
//! dedicated named-module build entrypoint small.

pub const model = @import("model.zig");
pub const projection = @import("projection.zig");

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

pub const max_transfer_payload = model.max_transfer_payload;
pub const max_transfer_records = model.max_transfer_records;
pub const max_transfer_name = model.max_transfer_name;
pub const max_transfer_revision = model.max_transfer_revision;

pub const FieldBinding = projection.FieldBinding;
pub const OwnedScene = projection.OwnedScene;
pub const project = projection.project;
