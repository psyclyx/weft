//! Portable plugin-facing files facade.
//!
//! This root deliberately contains only the host-independent model,
//! projection, workspace, and action contracts. Runtime integration lives in
//! the sandbox guest adapter, keeping it impossible for portable files users
//! to acquire native registries accidentally.

const std = @import("std");

pub const model = @import("weft_files_model");
pub const workspace = @import("weft_files_workspace");
pub const projection = @import("weft_files_projection");
pub const actions = @import("weft_files_actions");
pub const text_rows = @import("weft_files_text_rows");

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
pub const PlanPolicy = model.PlanPolicy;
pub const PastePlacement = model.PastePlacement;
pub const PasteAnchor = model.PasteAnchor;

pub const WorkspaceError = workspace.Error;
pub const directoryFromDescriptor = workspace.directoryFromDescriptor;
pub const reconcileListing = workspace.reconcileListing;
pub const reconcileChildListing = workspace.reconcileChildListing;
pub const observedChild = workspace.observedChild;
pub const validateListing = workspace.validateListing;
pub const sameDirectory = workspace.sameDirectory;

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
pub const decodeEntryTransferWithAttachment = model.decodeEntryTransferWithAttachment;

pub const FieldBinding = projection.FieldBinding;
pub const ProjectionOptions = projection.Options;
pub const OwnedScene = projection.OwnedScene;
pub const project = projection.project;
pub const projectWith = projection.projectWith;
pub const metadata_column = projection.metadata_column;
pub const mode_column = projection.mode_column;
pub const name_column = projection.name_column;
pub const original_column = projection.original_column;
pub const indent_cells = projection.indent_cells;
pub const permissions_edit_action = projection.permissions_edit_action;
pub const create_file_action = projection.create_file_action;
pub const create_directory_action = projection.create_directory_action;
pub const rowNodeId = projection.rowNodeId;
pub const nameNodeId = projection.nameNodeId;
pub const modeNodeId = projection.modeNodeId;
pub const rootNodeId = projection.rootNodeId;
pub const modelRowId = projection.modelRowId;

pub const ActionController = actions.Controller;
pub const ActionError = actions.Error;

test {
    std.testing.refAllDecls(@This());
}
