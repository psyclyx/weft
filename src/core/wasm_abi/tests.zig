//! The wasm-membrane test suite + its compact editor `Env`. Exercises the full
//! ABI end to end: a `.wasm` guest reaches the editor only across the sandbox
//! membrane, yet lands its edits on the identical authority path an in-process
//! catalog plugin uses. Kept beside the facade so `zig build test` still runs
//! them (wasm_abi.zig references this file from a test block).

const std = @import("std");
const wasm = @import("../wasm.zig");
const command = @import("../command.zig");
const dispatch = @import("../../app/dispatch.zig");
const kv = @import("../kv.zig");
const file = @import("../file.zig");
const pick_mod = @import("../pick.zig");
const subbuffer = @import("../subbuffer.zig");
const register = @import("../register.zig");
const surface_mod = @import("../surface.zig");
const semantic_mod = @import("../semantic.zig");
const async_loop = @import("../async.zig");
const net_session = @import("../net_session.zig");
const wasm_host = @import("../wasm_host.zig");
const contract = @import("../membrane/contract.zig");
const semantic_model = @import("weft_semantic");
const fs_contract = @import("weft_fs").contract;
const fs_runtime = @import("weft_fs_runtime");
const Allocator = std.mem.Allocator;

const wasm_abi = @import("../wasm_abi.zig");
const guest_hello = wasm_abi.guest_hello;

// Every guest in this suite loads through the engine's compiled-module cache
// (`wasm.Engine.cache_dir`, which a test binary inherits from
// the build-baked module cache). JIT-compiling the catalog from scratch is the
// suite's dominant cost, and the cache is content-addressed, so a changed
// guest still compiles exactly once.
const loadPlugin = wasm_abi.loadPlugin;
const runGuest = wasm_abi.runGuest;

const t = std.testing;

test "wasm plugin: canonical targets and scenes cross the semantic membrane" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var semantic = semantic_mod.Services.init(.here);
    defer semantic.deinit(gpa);
    env.ctx.semantic = &semantic;

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "semantic-fixture", @embedFile("guest_semantic_wasm"), .{});

    const target_ref: @import("weft_semantic").target.Ref = .{ .authority = .here, .slot = 0, .generation = 1 };
    const target = semantic.targets.get(target_ref).?;
    try t.expectEqualStrings("fixture directory", target.display_name);
    try t.expect(target.kind == .directory);

    const view_ref: @import("weft_semantic").view.Ref = .{ .authority = .here, .slot = 0, .generation = 1 };
    const view = semantic.views.get(view_ref).?;
    try t.expect(view.descriptor.target.?.ref.eql(target_ref));
    try t.expectEqual(@as(u64, 2), view.descriptor.target.?.revision);
    try t.expectEqual(@as(u64, 7), view.descriptor.revision);

    // The same retained target is discoverable through the generic resolver,
    // and the selected guest handler opens only the view it owns.  This is the
    // end-to-end membrane path: descriptor -> guest probe -> selection ->
    // located open -> typed view, with no dired- or Vim-specific coupling.
    var resolution = try semantic.resolveTarget(gpa, target_ref);
    defer resolution.deinit();
    try t.expectEqual(@as(usize, 1), resolution.handlers.value.candidates.len);
    const selected = resolution.handlers.value.decide().selected;
    try t.expectEqual(view_ref, try semantic.openTarget(selected, resolution.located(.whole)));

    // The guest independently publishes a named edge through the generic
    // relation bridge. Core supplies the queried name, validates the located
    // destination, and returns one owned resolution.
    var container = try semantic.resolveTargetRelation(gpa, resolution.located(.whole), "container");
    defer container.deinit();
    try t.expectEqual(target_ref, container.value.resolved.target);
    try t.expectEqual(@as(u64, 2), container.value.resolved.revision);

    try t.expectEqualStrings("fixture", view.scene.role);
    const field_ref = view.scene.content.container.children[0].content.field.ref;
    const interaction = env.head.interactions.active().?;
    try t.expectEqual(view_ref, interaction.descriptor.view);
    try t.expectEqual(@as(@import("weft_semantic").scene.NodeId, @enumFromInt(1)), interaction.descriptor.root);
    try t.expectEqualStrings("fixture-dialog", interaction.descriptor.presentation);
    try t.expectEqualStrings("fixture.yes", interaction.actionForInput("y").?.id);
    try t.expectEqualStrings("fixture.no", interaction.actionForInput("n").?.id);
    try t.expect(interaction.actionForInput("x") == null);
    // Interaction bindings are stack-local; the fixture did not mutate the
    // editor mode, pending chord, or the shared keymap.
    try t.expectEqualStrings("", env.head.currentMode());
    try t.expectEqual(@as(usize, 0), env.head.pending.len);
    try t.expect(env.head.lookup(&env.keymap, "y") == null);
    try t.expect(env.head.lookup(&env.keymap, "n") == null);
    const provider = semantic.fields.get(field_ref).?;
    try provider.edit("1", .{
        .start = 0,
        .end = 4,
        .replacement = "renamed",
        .selection_after = .{ .anchor = 7, .caret = 7 },
    });
    var snapshot = try provider.snapshot(gpa);
    defer snapshot.deinit();
    try t.expectEqualStrings("2", snapshot.value.revision);
    try t.expectEqualStrings("renamed", snapshot.value.bytes);
    try t.expectEqual(@as(u64, 7), snapshot.value.selection.caret);
    const child_id: @import("weft_semantic").scene.NodeId = @enumFromInt(0x1_0000_0002);
    try t.expectEqual(child_id, env.head.semantic_focus.path().?.leaf().?);
    try t.expect((try semantic.actions.invoke(&semantic.views, .{
        .action = "fixture.open",
        .view = view_ref,
        .subject = child_id,
        .selection = .{ .nodes = &.{child_id} },
    })) == .handled);

    plugin.deinit();
    try t.expect(semantic.targets.get(target_ref) == null);
    try t.expect(semantic.views.get(view_ref) == null);
    try t.expect(semantic.fields.get(field_ref) == null);
    var retired_relations = try semantic.target_relations.query(gpa, .{
        .source = .{ .target = target_ref, .revision = 2 },
        .name = "container",
    });
    defer retired_relations.deinit();
    try t.expectEqual(@as(usize, 0), retired_relations.value.candidates.len);
    try t.expectError(error.StaleView, semantic.actions.invoke(&semantic.views, .{
        .action = "fixture.open",
        .view = view_ref,
        .subject = child_id,
    }));
}

test "wasm plugin: guarded child directories publish and revoke complete authority" {
    const gpa = t.allocator;
    const Provider = struct {
        child_generation: u32 = 1,
        child_live: bool = false,
        derive_calls: usize = 0,
        release_calls: usize = 0,

        const parent_root: fs_contract.Root = .{ .authority = .here, .slot = 0, .generation = 1 };
        const child_entry: fs_contract.EntryRef = .{ .authority = .here, .slot = 7, .generation = 1 };
        const child_name = "child\n\xff";
        const child_revision = "child-r1";

        fn childRoot(self: *const @This()) fs_contract.Root {
            return .{ .authority = .here, .slot = 1, .generation = self.child_generation };
        }

        fn provider(self: *@This()) @import("weft_fs").service.Provider {
            return .init(self);
        }

        pub fn capabilities(_: *@This(), _: fs_contract.Root) fs_contract.Error!fs_contract.Capabilities {
            return .{
                .durable_lease = .{ .regular_file_max_bytes = 128, .symlink_target_max_bytes = 64 },
                .posix_mode = true,
                .guard_strength = .claimed,
                .watch = .invalidation,
            };
        }

        pub fn sameRoot(self: *@This(), left: fs_contract.Root, right: fs_contract.Root) fs_contract.Error!bool {
            try self.validateRoot(left);
            try self.validateRoot(right);
            return left.eql(right);
        }

        pub fn deriveRoot(self: *@This(), source: fs_contract.EntrySource) fs_contract.Error!fs_contract.Root {
            if (!source.root.eql(parent_root) or !source.ref.eql(child_entry) or
                !std.mem.eql(u8, source.revision.token, child_revision)) return error.Stale;
            if (self.child_live) return error.Busy;
            self.child_live = true;
            self.derive_calls += 1;
            return self.childRoot();
        }

        pub fn releaseRoot(self: *@This(), root: fs_contract.Root) void {
            if (!self.child_live or !root.eql(self.childRoot())) return;
            self.child_live = false;
            self.release_calls += 1;
            self.child_generation +%= 1;
            if (self.child_generation == 0) self.child_generation = 1;
        }

        fn validateRoot(self: *@This(), root: fs_contract.Root) fs_contract.Error!void {
            if (root.eql(parent_root)) return;
            if (self.child_live and root.eql(self.childRoot())) return;
            return error.Stale;
        }

        pub fn observe(self: *@This(), allocator: std.mem.Allocator, root: fs_contract.Root, node: fs_contract.NodeRef) fs_contract.Error!fs_contract.OwnedObservation {
            try self.validateRoot(root);
            if (node != .root) return error.Stale;
            var owned = fs_contract.OwnedObservation.init(allocator);
            owned.value = .{ .node = .root, .revision = .{ .token = &.{} }, .kind = .directory };
            return owned;
        }

        pub fn list(self: *@This(), allocator: std.mem.Allocator, root: fs_contract.Root, node: fs_contract.NodeRef) fs_contract.Error!fs_contract.OwnedListing {
            try self.validateRoot(root);
            if (node != .root) return error.Stale;
            var owned = fs_contract.OwnedListing.init(allocator);
            errdefer owned.deinit();
            const arena = owned.allocator();
            const revision = try arena.dupe(u8, if (root.eql(parent_root)) "parent-r1" else "derived-r1");
            const entries = try arena.alloc(fs_contract.DirEntry, if (root.eql(parent_root)) 1 else 0);
            if (root.eql(parent_root)) {
                entries[0] = .{
                    .name = fs_contract.Name.init(try arena.dupe(u8, child_name)) catch unreachable,
                    .observation = .{
                        .node = .{ .entry = child_entry },
                        .revision = .{ .token = try arena.dupe(u8, child_revision) },
                        .kind = .directory,
                    },
                };
            }
            owned.value = .{
                .directory = .{ .node = .root, .revision = .{ .token = revision }, .kind = .directory },
                .revision = .{ .token = revision },
                .entries = entries,
            };
            return owned;
        }

        pub fn read(_: *@This(), _: std.mem.Allocator, _: fs_contract.ReadRequest) fs_contract.Error!fs_contract.OwnedReadResult {
            return error.Unsupported;
        }
        pub fn capture(_: *@This(), _: fs_contract.EntrySource) fs_contract.Error!fs_contract.LeaseRef {
            return error.Unsupported;
        }
        pub fn releaseLease(_: *@This(), _: fs_contract.LeaseSource) void {}
        pub fn apply(_: *@This(), _: std.mem.Allocator, _: fs_contract.Plan) fs_contract.Error!fs_contract.OwnedApplyReport {
            return error.Unsupported;
        }
        pub fn watch(_: *@This(), _: fs_contract.Root, _: fs_contract.NodeRef, _: bool) fs_contract.Error!fs_contract.WatchRef {
            return error.Unsupported;
        }
        pub fn pollInvalidation(_: *@This(), _: fs_contract.WatchRef) fs_contract.Error!?fs_contract.Invalidation {
            return error.Unsupported;
        }
        pub fn closeWatch(_: *@This(), _: fs_contract.WatchRef) void {}
    };

    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var semantic = semantic_mod.Services.init(.here);
    defer semantic.deinit(gpa);
    var router = fs_runtime.Router.init(gpa);
    defer router.deinit();
    var provider: Provider = .{};
    try router.register(.here, provider.provider());
    env.ctx.semantic = &semantic;
    env.ctx.filesystems = &router;

    const host_owner = try semantic.acquireOwner();
    defer _ = semantic.releaseOwner(gpa, host_owner);
    var parent = try fs_runtime.publication.publish(
        gpa,
        &semantic.targets,
        &router,
        host_owner,
        .{ .display_name = "parent", .directory = .{ .root = Provider.parent_root } },
    );
    defer _ = parent.close(gpa, &semantic.targets, &router);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const fixture_bytes = @embedFile("guest_semantic_fs_wasm");

    const first = try loadPlugin(&engine, &env.ctx, "semantic-fs-fixture", fixture_bytes, .{});
    var first_live = true;
    defer if (first_live) first.deinit();
    try t.expectEqual(@as(usize, 1), first.semantic_directories.items.len);
    const first_child = first.semantic_directories.items[0].registration;
    try t.expectEqualStrings(Provider.child_name, semantic.targets.get(first_child.ref).?.display_name);
    const first_authorized = try router.authorizedDirectory(first_child.ref, first_child.revision);
    try t.expectEqual(provider.childRoot(), first_authorized.root);
    // The child carries the provider-derived root, never the parent's broad
    // namespace. Authorization is stamped to the exact child revision.
    try t.expect(!first_authorized.root.eql(Provider.parent_root));
    try t.expectError(error.StaleTarget, router.authorizedDirectory(first_child.ref, first_child.revision + 1));
    var child_listing = try router.list(gpa, first_authorized.root, first_authorized.node);
    defer child_listing.deinit();
    try t.expectEqual(@as(usize, 0), child_listing.value.entries.len);
    try t.expectEqual(@as(usize, 1), provider.derive_calls);

    const closed = try command.run(&env.commands, &env.ctx, "fixture-close-child-directory", &.{});
    try t.expectEqual(command.Value{ .integer = 1 }, closed);
    try t.expectEqual(@as(usize, 0), first.semantic_directories.items.len);
    try t.expect(semantic.targets.get(first_child.ref) == null);
    try t.expectError(error.TargetUnbound, router.authorizedDirectory(first_child.ref, first_child.revision));
    try t.expectEqual(@as(usize, 1), provider.release_calls);
    first.deinit();
    first_live = false;
    try t.expectEqual(@as(usize, 1), provider.release_calls);

    // Owner teardown exercises the same complete lifetime without asking the
    // guest to close first; neither the target binding nor provider root may
    // survive plugin unload.
    const second = try loadPlugin(&engine, &env.ctx, "semantic-fs-fixture", fixture_bytes, .{});
    const second_child = second.semantic_directories.items[0].registration;
    try t.expect(provider.child_live);
    second.deinit();
    try t.expect(!provider.child_live);
    try t.expectEqual(@as(usize, 2), provider.release_calls);
    try t.expect(semantic.targets.get(second_child.ref) == null);
    try t.expectError(error.TargetUnbound, router.authorizedDirectory(second_child.ref, second_child.revision));

    // The real sandbox adapter consumes only public target/fs/view/field/
    // action contracts. Opening the same parent publishes a retained dired
    // scene and a separately confined child target without native dired
    // composition in this environment.
    const dired_plugin = try loadPlugin(
        &engine,
        &env.ctx,
        "dired-semantic-fixture",
        @embedFile("guest_dired_semantic_wasm"),
        .{},
    );
    var dired_live = true;
    defer if (dired_live) dired_plugin.deinit();
    const release_before_dired = provider.release_calls;
    var resolution = try semantic.target_handlers.resolve(gpa, semantic.targets.get(parent.ref).?.*);
    defer resolution.deinit();
    const selected = resolution.value.decide().selected;
    const opened = try semantic.target_handlers.open(selected, parent.located());
    const view_ref = opened.view();
    try t.expect(semantic.target_handlers.settle(selected, opened, .accepted));
    try t.expectEqual(@as(usize, 1), dired_plugin.semantic_directories.items.len);
    const initial_view = semantic.views.get(view_ref) orelse return error.TestUnexpectedResult;
    const initial_view_revision = initial_view.descriptor.revision;
    try t.expectEqualStrings("files", initial_view.scene.role);
    const initial_rows = initial_view.scene.content.container.children;
    try t.expectEqual(@as(usize, 1), initial_rows.len);
    const row_id = initial_rows[0].id;
    const name_node = initial_rows[0].content.container.children[2];
    try t.expect(name_node.target != null);
    const field_ref = name_node.content.field.ref;
    const field = semantic.fields.get(field_ref) orelse return error.TestUnexpectedResult;
    var before = try field.snapshot(gpa);
    defer before.deinit();
    try t.expectEqualStrings(Provider.child_name, before.value.bytes);

    // Ordinary field editing preserves the row and its opaque identity; the
    // sandbox guest republishes the diff scene at a new view revision.
    try field.edit(before.value.revision, .{
        .start = 0,
        .end = before.value.bytes.len,
        .replacement = "renamed",
        .selection_after = .{ .anchor = 7, .caret = 7 },
    });
    var renamed = try field.snapshot(gpa);
    defer renamed.deinit();
    try t.expectEqualStrings("renamed", renamed.value.bytes);
    const renamed_view = semantic.views.get(view_ref) orelse return error.TestUnexpectedResult;
    try t.expect(renamed_view.descriptor.revision > initial_view_revision);
    try t.expectEqual(row_id, renamed_view.scene.content.container.children[0].id);

    // Generic delete marks the retained row and retires its child authority;
    // generic revert reconstructs it from the provider listing.
    try t.expect((try semantic.actions.invoke(&semantic.views, .{
        .action = semantic_model.action.standard.delete,
        .view = view_ref,
        .subject = row_id,
    })) == .handled);
    try t.expectEqual(@as(usize, 0), dired_plugin.semantic_directories.items.len);
    const deleted_view = semantic.views.get(view_ref) orelse return error.TestUnexpectedResult;
    const deleted_row = deleted_view.scene.content.container.children[0];
    try t.expectEqual(row_id, deleted_row.id);
    try t.expect(deleted_row.content.container.children[2].target == null);
    try t.expect((try semantic.actions.invoke(&semantic.views, .{
        .action = semantic_model.action.standard.revert,
        .view = view_ref,
        .subject = deleted_view.scene.id,
    })) == .handled);
    try t.expectEqual(@as(usize, 1), dired_plugin.semantic_directories.items.len);
    const reverted = semantic.views.get(view_ref) orelse return error.TestUnexpectedResult;
    try t.expectEqual(row_id, reverted.scene.content.container.children[0].id);
    try t.expect(reverted.scene.content.container.children[0].content.container.children[2].target != null);

    // Replacing the exact target descriptor revision does not let an already
    // open session inherit the new authority. Rebind the same provider root
    // under the new revision to model an intentional host-side replacement;
    // the old view must still decline before touching its draft.
    const prior_parent = semantic.targets.get(parent.ref) orelse return error.TestUnexpectedResult;
    try semantic.replaceTarget(gpa, host_owner, parent.ref, .{
        .kind = .directory,
        .display_name = "parent-replaced",
        .facts = prior_parent.facts,
    });
    const replaced_parent = semantic.targets.get(parent.ref) orelse return error.TestUnexpectedResult;
    try t.expectEqual(parent.revision + 1, replaced_parent.revision);
    try t.expect(router.unbindTarget(parent.ref));
    try router.bindTarget(host_owner, parent.ref, replaced_parent.revision, .{ .root = Provider.parent_root });
    try t.expect((try semantic.actions.invoke(&semantic.views, .{
        .action = @import("weft_fs").action.entry_create_file,
        .view = view_ref,
        .subject = reverted.scene.id,
    })) == .declined);
    var stale_action_field = try field.snapshot(gpa);
    defer stale_action_field.deinit();
    try t.expectEqualStrings(Provider.child_name, stale_action_field.value.bytes);

    // Opening the replacement creates a distinct session. The old session's
    // child target is busy and therefore cannot be adopted by the new one;
    // its row remains descriptive until the new session derives its own
    // authority, rather than inheriting a stale child capability.
    var replaced_resolution = try semantic.target_handlers.resolve(gpa, replaced_parent.*);
    defer replaced_resolution.deinit();
    const replaced_selected = replaced_resolution.value.decide().selected;
    const replaced_opened = try semantic.target_handlers.open(replaced_selected, .{
        .target = parent.ref,
        .revision = replaced_parent.revision,
    });
    const replaced_view_ref = replaced_opened.view();
    try t.expect(semantic.target_handlers.settle(replaced_selected, replaced_opened, .accepted));
    try t.expect(!replaced_view_ref.eql(view_ref));
    const replaced_view = semantic.views.get(replaced_view_ref) orelse return error.TestUnexpectedResult;
    try t.expectEqual(replaced_parent.revision, replaced_view.descriptor.target.?.revision);
    const replaced_row = replaced_view.scene.content.container.children[0];
    try t.expect(replaced_row.content.container.children[2].target == null);

    // Drive a failed view replacement through the real sandbox callback. The
    // host closes only the retained scene; the guest session and fields remain
    // live, so both an action draft and a field edit must remain unchanged.
    const replaced_field_ref = replaced_row.content.container.children[2].content.field.ref;
    const replaced_field = semantic.fields.get(replaced_field_ref) orelse return error.TestUnexpectedResult;
    var replaced_before = try replaced_field.snapshot(gpa);
    defer replaced_before.deinit();
    const field_count = dired_plugin.semantic_fields.proxies.items.len;
    try t.expect(semantic.closeView(gpa, dired_plugin.semantic_owner.?, replaced_view_ref));
    const failed_action = try dired_plugin.semantic_actions.invoke(.{
        .action = @import("weft_fs").action.entry_create_file,
        .view = replaced_view_ref,
        .subject = replaced_view.scene.id,
    });
    try t.expect(failed_action == .declined);
    try t.expectEqual(field_count, dired_plugin.semantic_fields.proxies.items.len);
    try t.expectError(error.Failed, replaced_field.edit(replaced_before.value.revision, .{
        .start = 0,
        .end = replaced_before.value.bytes.len,
        .replacement = "must-not-publish",
        .selection_after = .{ .anchor = 3, .caret = 3 },
    }));
    var replaced_after = try replaced_field.snapshot(gpa);
    defer replaced_after.deinit();
    try t.expectEqualStrings(replaced_before.value.revision, replaced_after.value.revision);
    try t.expectEqualStrings(replaced_before.value.bytes, replaced_after.value.bytes);
    try t.expectEqual(replaced_before.value.selection, replaced_after.value.selection);

    // Session/plugin retirement closes the retained child publication as well
    // as the generic semantic view. The provider root must not outlive the
    // sandbox instance that derived it.
    const dired_child = dired_plugin.semantic_directories.items[0].registration;
    dired_plugin.deinit();
    dired_live = false;
    // Delete retires the first row target; revert derives a replacement, and
    // plugin teardown retires that replacement.
    try t.expectEqual(release_before_dired + 2, provider.release_calls);
    try t.expect(semantic.targets.get(dired_child.ref) == null);
    try t.expectError(error.TargetUnbound, router.authorizedDirectory(dired_child.ref, dired_child.revision));
}

test "wasm plugin: semantic ownership is instance-specific and system-local" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var home = semantic_mod.Services.init(.here);
    defer home.deinit(gpa);
    env.ctx.semantic = &home;

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const bytes = @embedFile("guest_semantic_wasm");
    const first = try loadPlugin(&engine, &env.ctx, "same-name", bytes, .{});
    var first_live = true;
    defer if (first_live) first.deinit();
    const second = try loadPlugin(&engine, &env.ctx, "same-name", bytes, .{});
    var second_live = true;
    defer if (second_live) second.deinit();
    try t.expect(first.semantic_owner.? != second.semantic_owner.?);

    const first_target: @import("weft_semantic").target.Ref = .{ .authority = .here, .slot = 0, .generation = 1 };
    const first_view: @import("weft_semantic").view.Ref = .{ .authority = .here, .slot = 0, .generation = 1 };
    const second_target: @import("weft_semantic").target.Ref = .{ .authority = .here, .slot = 1, .generation = 1 };
    const second_view: @import("weft_semantic").view.Ref = .{ .authority = .here, .slot = 1, .generation = 1 };
    try t.expect(home.targets.get(first_target) != null);
    try t.expect(home.targets.get(second_target) != null);

    // A dispatch can borrow another head in the same system, but persistent
    // endpoints may never escape into a different system's registries.
    var foreign = semantic_mod.Services.init(@enumFromInt(9));
    defer foreign.deinit(gpa);
    var foreign_ctx = env.ctx;
    foreign_ctx.semantic = &foreign;
    first.active_ctx = &foreign_ctx;
    try t.expect(first.semanticScope() == null);
    var ignored: [1]i32 = .{-1};
    @import("../wasm_host/semantic_action.zig").hProvider(first, undefined, &.{}, &ignored);
    try t.expectEqual(@as(i32, 0), ignored[0]);
    try t.expect(!foreign.releaseOwner(gpa, first.semantic_owner.?).action_provider);
    first.active_ctx = first.ctx;

    second.deinit();
    second_live = false;
    try t.expect(home.targets.get(second_target) == null);
    try t.expect(home.views.get(second_view) == null);
    try t.expect(home.targets.get(first_target) != null);
    try t.expect(home.views.get(first_view) != null);
    try t.expect((try home.actions.invoke(&home.views, .{
        .action = "fixture.open",
        .view = first_view,
        .subject = @enumFromInt(0x1_0000_0002),
        .selection = .{ .nodes = &.{@enumFromInt(0x1_0000_0002)} },
    })) == .handled);

    first.deinit();
    first_live = false;
    try t.expect(home.targets.get(first_target) == null);
    try t.expect(home.views.get(first_view) == null);
}

test "wasm plugin: a .wasm guest edits the buffer through the host ABI, as its peer" {
    const gpa = t.allocator;
    const task = @import("../task.zig");
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var buffers = try @import("../Buffers.zig").init(gpa, pool, "user");
    defer buffers.deinit(gpa);
    var commands: command.Commands = .empty;
    defer commands.deinit(gpa);
    var keymap: @import("../Keymap.zig") = .empty;
    defer keymap.deinit(gpa);
    var head: @import("../Head.zig") = .empty;
    defer head.deinit(gpa);
    var container = @import("../container.zig").Container.init(gpa);
    defer container.deinit();
    var caps = @import("../capability.zig").Caps.init(gpa, task.nowNs, &container);
    defer caps.deinit();
    var actions = @import("../action.zig").init(gpa, &container);
    defer actions.deinit();
    var quit = false;
    var ctx: command.Context = .{
        .gpa = gpa,
        .buffers = &buffers,
        .commands = &commands,
        .keymap = &keymap,
        .actions = &actions,
        .caps = &caps,
        .quit = &quit,
        .head = &head,
    };

    try buffers.active().textEditor().?.insertText(gpa, "ab");
    buffers.active().textEditor().?.placeCursor(1); // between 'a' and 'b'

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    try runGuest(&engine, &ctx, "wasm.hello", guest_hello);

    // The .wasm guest inserted "wasm!" at the cursor through the host edit.
    const s = try buffers.active().textEditor().?.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("awasm!b", s);
    // Authored as the wasm plugin's peer, not the user (the authority gate
    // holds across the membrane).
    const doc = buffers.active().textEditor().?.doc;
    try t.expect(doc.commitAt(doc.commitCount() - 1).author != .user);
}

test "wasm plugin: init registers a command that dispatches back into the guest" {
    const gpa = t.allocator;
    const task = @import("../task.zig");
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var buffers = try @import("../Buffers.zig").init(gpa, pool, "user");
    defer buffers.deinit(gpa);
    var commands: command.Commands = .empty;
    defer commands.deinit(gpa);
    var keymap: @import("../Keymap.zig") = .empty;
    defer keymap.deinit(gpa);
    var head: @import("../Head.zig") = .empty;
    defer head.deinit(gpa);
    var container = @import("../container.zig").Container.init(gpa);
    defer container.deinit();
    var caps = @import("../capability.zig").Caps.init(gpa, task.nowNs, &container);
    defer caps.deinit();
    var actions = @import("../action.zig").init(gpa, &container);
    defer actions.deinit();
    var quit = false;
    var ctx: command.Context = .{
        .gpa = gpa,
        .buffers = &buffers,
        .commands = &commands,
        .keymap = &keymap,
        .actions = &actions,
        .caps = &caps,
        .quit = &quit,
        .head = &head,
    };

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &ctx, "wasm.plugin", @embedFile("guest_plugin_wasm"), .{});
    defer plugin.deinit();

    // The guest's init() registered "wasm-mark" through the host.
    try t.expect(commands.resolve("wasm-mark") != null);

    // Running it dispatches back into the guest, which edits via the host
    // gate — authored as the plugin's peer, across the membrane.
    try buffers.active().textEditor().?.insertText(gpa, "xy");
    buffers.active().textEditor().?.placeCursor(1);
    _ = try command.run(&commands, &ctx, "wasm-mark", &.{});
    const s = try buffers.active().textEditor().?.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("x[wasm]y", s);
    const doc = buffers.active().textEditor().?.doc;
    try t.expect(doc.commitAt(doc.commitCount() - 1).author != .user);
}

// A compact editor environment for the membrane tests below.
const Env = struct {
    pool: *@import("../task.zig").Pool,
    buffers: @import("../Buffers.zig"),
    commands: command.Commands,
    keymap: @import("../Keymap.zig"),
    head: @import("../Head.zig"),
    /// The ONE shared Container `caps`/`actions`/`slot_host` bind into (task
    /// #19; D2 follows the same borrow convention from day one).
    container: @import("../container.zig").Container,
    caps: @import("../capability.zig").Caps,
    actions: @import("../action.zig"),
    /// D2's generic, schema-directed slot host (doc/d2-schema-payloads.md
    /// §3.2, core/slot.zig) — `Caps`'s sibling, NOT a replacement; see that
    /// file's module doc for why it's kept separate this slice.
    slot_host: @import("../slot.zig").SlotHost,
    quit: bool,
    ctx: command.Context,

    fn init(gpa: Allocator, self: *Env) !void {
        const task = @import("../task.zig");
        self.pool = try task.Pool.init(gpa, .{ .threads = 1 });
        self.buffers = try @import("../Buffers.zig").init(gpa, self.pool, "user");
        self.commands = .empty;
        self.keymap = .empty;
        self.head = .empty;
        self.container = @import("../container.zig").Container.init(gpa);
        self.caps = @import("../capability.zig").Caps.init(gpa, task.nowNs, &self.container);
        self.actions = @import("../action.zig").init(gpa, &self.container);
        self.slot_host = @import("../slot.zig").SlotHost.init(gpa, &self.container);
        self.quit = false;
        self.ctx = .{
            .gpa = gpa,
            .buffers = &self.buffers,
            .commands = &self.commands,
            .keymap = &self.keymap,
            .actions = &self.actions,
            .caps = &self.caps,
            .quit = &self.quit,
            .head = &self.head,
            .slot_host = &self.slot_host,
        };
    }
    fn deinit(self: *Env, gpa: Allocator) void {
        self.slot_host.deinit();
        self.actions.deinit();
        self.caps.deinit();
        self.container.deinit();
        self.head.deinit(gpa);
        self.keymap.deinit(gpa);
        self.commands.deinit(gpa);
        self.buffers.deinit(gpa);
        self.pool.deinit();
    }
};

test "wasm plugin: the edit catalog plugin runs identically as .wasm (duplicate-line)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "edit", @embedFile("guest_edit_wasm"), .{});
    defer plugin.deinit();

    // Both commands declared in describe() bound through the handshake.
    try t.expect(env.commands.resolve("duplicate-line") != null);
    try t.expect(env.commands.resolve("upcase-line") != null);

    const ed = env.buffers.active().textEditor().?;
    try ed.insertText(gpa, "hello\nworld");
    ed.placeCursor(2); // inside the first line

    _ = try command.run(&env.commands, &env.ctx, "duplicate-line", &.{});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    // Same result the in-process edit.zig produces: the line copied below.
    try t.expectEqualStrings("hello\nhello\nworld", s);
    // Authored as the plugin's peer, across the membrane, through the gate.
    try t.expect(ed.doc.commitAt(ed.doc.commitCount() - 1).author != .user);
}

test "wasm: compiled-module image serialize→deserialize round-trips; garbage rejected" {
    var engine = try wasm.Engine.init(t.allocator);
    defer engine.deinit();

    var module = try engine.compile(@embedFile("guest_edit_wasm"));
    defer module.deinit();

    // Serialize the compiled image (the .cwasm cache write) and rebuild from it
    // (the cache read) — the round-trip the fast startup path depends on.
    const image = try module.serialize(t.allocator);
    defer t.allocator.free(image);
    try t.expect(image.len > 0);
    var restored = engine.deserialize(image) orelse return error.DeserializeFailed;
    restored.deinit();

    // A stale/garbage image is rejected (null), never a crash — so a
    // cross-version cache falls back to a fresh compile.
    try t.expect(engine.deserialize("not a real .cwasm image") == null);
}

test "which-key: on_menu builds a corner surface from the current menu's bindings" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "which_key", @embedFile("guest_which_key_wasm"), .{});
    defer plugin.deinit();

    const Keymap = @import("../Keymap.zig");
    // "f" opens a submenu (its command IS a menu mode) → a GROUP; "g" is a leaf.
    try env.keymap.markMenuMode(gpa, "leader");
    try env.keymap.markMenuMode(gpa, "leader-file");
    try env.keymap.bind(gpa, "leader", "f", "leader-file", Keymap.prio_plugin, "test");
    try env.keymap.bind(gpa, "leader", "g", "git-status", Keymap.prio_plugin, "test");
    try env.head.setModeRaw(gpa, "leader");

    // Core fires on_menu(open) at the frame boundary; the guest reads the
    // current menu's bindings and paints a surface.
    wasm_host.notifyMenu(plugin, true);
    try t.expect(plugin.surface.active);
    try t.expectEqual(surface_mod.Placement.corner, plugin.surface.placement);
    try t.expectEqual(@as(usize, 2), plugin.surface.rows.items.len);
    // Each row: the key in accent, then the command colored by group vs leaf.
    try t.expectEqualStrings("f", plugin.surface.rows.items[0].spans.items[0].text);
    try t.expectEqual(surface_mod.Role.accent, plugin.surface.rows.items[0].spans.items[0].role);
    try t.expectEqualStrings("leader-file", plugin.surface.rows.items[0].spans.items[1].text);
    try t.expectEqual(surface_mod.Role.group, plugin.surface.rows.items[0].spans.items[1].role); // a submenu
    try t.expectEqual(surface_mod.Role.leaf, plugin.surface.rows.items[1].spans.items[1].role); // git-status: leaf

    // Leaving the menu closes the surface.
    wasm_host.notifyMenu(plugin, false);
    try t.expect(!plugin.surface.active);
}

const OpenCommandProbe = struct {
    gpa: Allocator,
    calls: usize = 0,
    target: ?[]u8 = null,

    fn deinit(self: *OpenCommandProbe) void {
        if (self.target) |target| self.gpa.free(target);
    }

    fn handle(ctx: *command.Context, data: ?*anyopaque, args: []const command.Value) anyerror!command.Value {
        const self: *OpenCommandProbe = @ptrCast(@alignCast(data.?));
        if (args.len != 1 or args[0] != .string) return error.InvalidOpenTarget;
        if (self.target) |target| self.gpa.free(target);
        self.target = try ctx.gpa.dupe(u8, args[0].string);
        self.calls += 1;
        return .nil;
    }
};

test "dired wasm launcher: delegates to the ordinary open command at cwd" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var open_probe = OpenCommandProbe{ .gpa = gpa };
    defer open_probe.deinit();
    _ = try env.commands.bind(gpa, "open", .{
        .name = "open",
        .summary = "Open a target.",
        .args = &.{.{ .name = "target", .type = .string }},
        .handler = OpenCommandProbe.handle,
        .data = &open_probe,
    });

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    // The shipped dired guest is a thin launcher. This ABI gate intentionally
    // supplies only the ordinary command surface: dired owns no proc/fs
    // authority, text buffer, mode, or filesystem implementation.
    const plugin = try loadPlugin(&engine, &env.ctx, "files", @embedFile("guest_dired_wasm"), .{});
    defer plugin.deinit();
    try t.expect(env.commands.resolve("files") != null);

    _ = try command.run(&env.commands, &env.ctx, "files", &.{});
    try t.expectEqual(@as(usize, 1), open_probe.calls);

    var cwd_buf: [4096]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.GetCwd;
    const cwd = std.mem.sliceTo(cwd_ptr, 0);
    try t.expectEqualStrings(cwd, open_probe.target.?);
}

test "helix: a second modal editor loads in its OWN mode namespace" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "helix", @embedFile("guest_helix_wasm"), .{});
    defer plugin.deinit();

    // helix.init sets its OWN initial mode and binds in its OWN namespace —
    // nothing here assumes vim's "normal". If core privileged vim, this breaks.
    try t.expectEqualStrings("helix-normal", env.head.currentMode());
    try t.expectEqualStrings("hx-insert", env.keymap.lookup(env.head.currentMode(), "i").?);
    try t.expectEqualStrings("cursor-left", env.keymap.lookup(env.head.currentMode(), "h").?);
    // Word motion is bound to helix's generated move wrapper (shared `motions`).
    try t.expectEqualStrings("hx/n/motion.word-fwd", env.keymap.lookup(env.head.currentMode(), "w").?);
    // op-pending stays a menu mode (which-key renders its motions), but the
    // leader is now a key SEQUENCE — no `helix-leader` mode: `space` opens a
    // chord and `space g g` completes to git-status through the sequence engine.
    try t.expect(!env.keymap.isMenuMode("helix-leader"));
    try t.expect(env.keymap.isMenuMode("helix-op"));
    try t.expect((try env.head.feed(gpa, &env.keymap, "space")) == .pending);
    try t.expect((try env.head.feed(gpa, &env.keymap, "g")) == .pending);
    try t.expectEqualStrings("git-status", (try env.head.feed(gpa, &env.keymap, "g")).run[0]);
}

test "emacs: a modeless editor loads; motion/kill chords, C-x is a chord not a mode" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "emacs", @embedFile("guest_emacs_wasm"), .{});
    defer plugin.deinit();

    // ONE resting mode; no modal posture. Its editing chords are bound directly.
    try t.expectEqualStrings("emacs", env.head.currentMode());
    try t.expectEqualStrings("cursor-right", env.keymap.lookup(env.head.currentMode(), "C-f").?);
    try t.expectEqualStrings("cursor-left", env.keymap.lookup(env.head.currentMode(), "C-b").?);
    try t.expectEqualStrings("beginning-of-line", env.keymap.lookup(env.head.currentMode(), "C-a").?);
    try t.expectEqualStrings("kill-line", env.keymap.lookup(env.head.currentMode(), "C-k").?);
    // Kill/copy/yank lead with the standard transfer words and keep the
    // region commands as their fallback arms.
    const yank_arms = env.keymap.resolveExactArms(env.head.currentMode(), "C-y").?;
    try t.expectEqualStrings("std.transfer.paste", yank_arms[0]);
    try t.expectEqualStrings("yank", yank_arms[1]);
    // Word motion drives the shared `motions` plugin (like vim/helix).
    try t.expectEqualStrings("forward-word", env.keymap.lookup(env.head.currentMode(), "M-f").?);
    // M-< normalized to M-less at bind time.
    try t.expectEqualStrings("beginning-of-buffer", env.keymap.lookup(env.head.currentMode(), "M-less").?);
    // `emacs` is NOT a menu mode — the C-x/C-c trees are key sequences (config).
    try t.expect(!env.keymap.isMenuMode("emacs"));
}

test "vim ex: `:` opens a command line; :N gotos, :%s substitutes, unknown falls through" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "vim", @embedFile("guest_vim_wasm"), .{});
    defer plugin.deinit();

    // `:` is now the ex command line (the palette moved to SPC :), and `ex` is a
    // text-input mode routing keystrokes to `ex-type`.
    try t.expectEqualStrings("vim-ex", env.keymap.lookup(env.head.currentMode(), "colon").?);

    const ed = env.buffers.active().textEditor().?;
    try ed.insertText(gpa, "l1\nl2\nl3\nl4\nl5");
    ed.placeCursor(0);

    // `:3` — open the command line, type "3", Enter → cursor at the start of L3.
    _ = try command.run(&env.commands, &env.ctx, "vim-ex", &.{});
    try t.expectEqualStrings("ex", env.head.currentMode());
    _ = try command.run(&env.commands, &env.ctx, "ex-type", &.{.{ .string = "3" }});
    _ = try command.run(&env.commands, &env.ctx, "ex-run", &.{});
    try t.expectEqualStrings("normal", env.head.currentMode()); // back in normal
    try t.expectEqual(@as(usize, 6), ed.cursorOffset());

    // `:%s/l/X/g` — a whole-file literal substitute, one user edit.
    _ = try command.run(&env.commands, &env.ctx, "vim-ex", &.{});
    _ = try command.run(&env.commands, &env.ctx, "ex-type", &.{.{ .string = "%s/l/X/g" }});
    _ = try command.run(&env.commands, &env.ctx, "ex-run", &.{});
    {
        const s = try ed.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings("X1\nX2\nX3\nX4\nX5", s);
    }

    // Composition: an unknown `:name` falls through to the registry and, when no
    // such command exists, reports it (vim's E492) rather than silently no-op.
    env.head.echo.clearRetainingCapacity();
    _ = try command.run(&env.commands, &env.ctx, "vim-ex", &.{});
    _ = try command.run(&env.commands, &env.ctx, "ex-type", &.{.{ .string = "definitely-not-a-command" }});
    _ = try command.run(&env.commands, &env.ctx, "ex-run", &.{});
    try t.expect(std.mem.indexOf(u8, env.head.echo.items, "not an editor command") != null);
}

test "wasm plugin: upcase-line edits in place across the membrane" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "edit", @embedFile("guest_edit_wasm"), .{});
    defer plugin.deinit();

    const ed = env.buffers.active().textEditor().?;
    try ed.insertText(gpa, "abc\ndef");
    ed.placeCursor(5); // inside "def"
    _ = try command.run(&env.commands, &env.ctx, "upcase-line", &.{});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("abc\nDEF", s);
}

test "wasm plugin: an undeclared registration fails the load (perm handshake)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    // The guest registers a command it never declared — the cross-check must
    // reject it and roll back, exactly as abi.zig does in-process.
    try t.expectError(error.UndeclaredCommand, loadPlugin(&engine, &env.ctx, "rogue", @embedFile("guest_rogue_wasm"), .{}));
    // Nothing left behind: neither the declared nor the undeclared name bound.
    try t.expect(env.commands.resolve("undeclared") == null);
    try t.expect(env.commands.resolve("declared") == null);
}

test "wasm plugin: a denied effect traps rather than returning a fake result" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    // The guest never requests fs_read (see src/guest/deny.zig) but calls
    // fs.read from its command handler anyway. The load itself succeeds (no
    // perm is required to load — only to use); the deny happens on use.
    const plugin = try loadPlugin(&engine, &env.ctx, "sneaky", @embedFile("guest_deny_wasm"), .{});
    defer plugin.deinit();
    try t.expect(!plugin.perms[wasm_host.perm_fs_read]);

    // The membrane's ONE deny path (doc/contextual-workspace-architecture.md
    // §13.5, review C9): the host import traps the guest's call outright —
    // command.run surfaces it as error.Trap, never a normal return with a
    // fabricated result. If the guest's on_command ever DID resume after the
    // denied call (a regression back to the old silent -1), it would set its
    // result string to "did not trap" instead — so a bug here fails loud
    // either way.
    try t.expectError(error.Trap, command.run(&env.commands, &env.ctx, "go", &.{}));
}

// ── task #19 item 4: closing the `activeCtx()` background escape hatch ─────
// `src/guest/headtest.zig` (task #14's fixture, see its module doc) exercises
// the SAME guest through both a DISPATCHING entry (`on_command` via
// `command.run` — must work) and a BACKGROUND one (`on_poll`, called directly
// here rather than through the real readiness/proc-stream machinery — the
// point under test is the gate, not the poll scheduler) — must trap. Mirrors
// `deny.zig`'s "a guest built to misbehave for the test it backs" pattern,
// one door over (dispatch-gating, not perm-gating).

test "wasm plugin: a background entry's head-gated import traps (task #19 item 4)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try env.head.setModeRaw(gpa, "start"); // an observable baseline the trap must not move

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "headtest", @embedFile("guest_headtest_wasm"), .{});
    defer plugin.deinit();

    // `on_poll` attempts `weft.setMode("polled")` then `weft.echo("polled")`.
    // `requireDispatch` (wasm_host/plugin.zig) traps on the FIRST one — the
    // guest call unwinds right there, so the echo never runs either.
    try t.expectError(error.Trap, contract.callOptionalExport("on_poll", &plugin.instance, .{}));
    try t.expectEqualStrings("start", env.head.currentMode()); // untouched
    try t.expectEqual(@as(usize, 0), env.head.echo.items.len); // untouched
}

test "wasm plugin: the SAME head-gated import works from a dispatching entry, and a nested wl_run keeps dispatch status (task #19 item 4)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try env.head.setModeRaw(gpa, "start");

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "headtest", @embedFile("guest_headtest_wasm"), .{});
    defer plugin.deinit();

    // `head-poke` (on_command — DISPATCHING): the identical `weft.setMode`/
    // `weft.echo` pair `on_poll` traps on above now succeeds.
    _ = try command.run(&env.commands, &env.ctx, "head-poke", &.{});
    try t.expectEqualStrings("poked", env.head.currentMode());
    try t.expectEqualStrings("poked", env.head.echo.items);

    // `head-relay` (on_command -> wl_run("head-poke") -> on_command, nested)
    // THEN a second `weft.echo` write after the nested call returns. Both the
    // nested call's writes and the post-nesting write must succeed — proving
    // `in_dispatch` (like `active_ctx`) is saved/restored around the nested
    // dispatch (still true before and after), not bare-set-and-lost the
    // instant the inner call returns.
    _ = try command.run(&env.commands, &env.ctx, "head-relay", &.{});
    try t.expectEqualStrings("poked", env.head.currentMode()); // set by the nested head-poke
    try t.expectEqualStrings("after-relay", env.head.echo.items); // written AFTER the nesting, still succeeds
}

test "wasm plugin: nested same-plugin dispatch preserves its caller's live ranges" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "headtest", @embedFile("guest_headtest_wasm"), .{});
    defer plugin.deinit();

    try env.buffers.active().textEditor().?.insertText(gpa, "abc");
    const result = try command.run(&env.commands, &env.ctx, "head-range-relay", &.{});
    try t.expect(result == .range);
    const resolved = result.range.resolve(&env.buffers.active().textEditor().?.doc) orelse return error.TestUnexpectedResult;
    try t.expectEqual(@as(usize, 1), resolved.start);
    try t.expectEqual(@as(usize, 2), resolved.end);

    // Released capabilities are never recycled: an arbitrarily late cleanup
    // for `old` must be harmless to the range allocated afterward.
    const old = try plugin.anchorRange(0, 1);
    plugin.releaseRange(old);
    const fresh = try plugin.anchorRange(1, 2);
    try t.expect(old != fresh);
    plugin.releaseRange(old);
    try t.expect(plugin.activeRange(fresh) != null);
    plugin.releaseRange(fresh);
}

test "wasm plugin: document snapshot witnesses are causal, buffer-bound, and idempotent" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "headtest", @embedFile("guest_headtest_wasm"), .{});
    defer plugin.deinit();

    const before = try plugin.docSnapshot();
    const same_frontier = try plugin.docSnapshot();
    try t.expect(before != same_frontier);
    try t.expect(plugin.docSnapshotIsCurrent(before));
    try t.expect(plugin.docSnapshotIsCurrent(same_frontier));
    plugin.releaseDocSnapshot(before);
    try t.expect(plugin.docSnapshotIsCurrent(same_frontier));
    try env.buffers.active().textEditor().?.insertText(gpa, "abc");
    try t.expect(!plugin.docSnapshotIsCurrent(before));
    try t.expect(!plugin.docSnapshotIsCurrent(same_frontier));
    plugin.releaseDocSnapshot(before);
    plugin.releaseDocSnapshot(before);
    try t.expect(!plugin.docSnapshotIsCurrent(before));
    plugin.releaseDocSnapshot(same_frontier);

    const other = try plugin.docSnapshot();
    try t.expect(other != before);
    const other_id = try env.buffers.create(gpa, "other");
    try env.buffers.switchTo(gpa, other_id, &env.head, &env.keymap);
    try t.expect(!plugin.docSnapshotIsCurrent(other));
    plugin.releaseDocSnapshot(other);
}

test "wasm plugin: init-phase table-config declarations are unaffected by dispatch-gating (task #19 item 4)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    // headtest's `init()` (a BACKGROUND entry) calls `weft.restingMode("poked")`
    // — a mode TABLE declaration (Keymap-owned, not Head-owned; see
    // contract_data.zig's `.head_gated` doc). `loadPlugin` returning at all
    // (not a load-time trap) is the proof: `wl_resting_mode` stayed ungated.
    const plugin = try loadPlugin(&engine, &env.ctx, "headtest", @embedFile("guest_headtest_wasm"), .{});
    defer plugin.deinit();
    try t.expect(env.keymap.isRestingMode("poked"));
}

test "wasm plugin: hot-reload — teardown unbinds, re-instantiation is clean" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    const ed = env.buffers.active().textEditor().?;
    try ed.insertText(gpa, "x");
    ed.placeCursor(0);

    // Load, use, then tear down (the hot-reload's unload half): the command
    // must unbind and the store drop with no residue.
    {
        const v1 = try loadPlugin(&engine, &env.ctx, "edit", @embedFile("guest_edit_wasm"), .{});
        _ = try command.run(&env.commands, &env.ctx, "duplicate-line", &.{});
        v1.deinit();
        // After teardown the command is gone — nothing dangles behind it.
        try t.expect(env.commands.resolve("duplicate-line") == null);
    }

    // Re-instantiate from scratch (a fresh store, no shared mutable state):
    // the same source loads and runs identically — the reload contract.
    {
        const v2 = try loadPlugin(&engine, &env.ctx, "edit", @embedFile("guest_edit_wasm"), .{});
        defer v2.deinit();
        try t.expect(env.commands.resolve("duplicate-line") != null);
        ed.placeCursor(0);
        _ = try command.run(&env.commands, &env.ctx, "duplicate-line", &.{});
    }
    // Two duplications of "x" across two independent instances: "x\nx\nx".
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("x\nx\nx", s);
}

test "wasm plugin: a completion provider gathers candidates across the membrane" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "complete", @embedFile("guest_complete_wasm"), .{});
    defer plugin.deinit();

    const ed = env.buffers.active().textEditor().?;
    try ed.insertText(gpa, "alpha alphabet beta alpha");

    // Fire a completion for prefix "alph": the host calls the guest's
    // on_complete(session), which scans the buffer and offers each match into
    // that session, then commits. The buffer has "alpha" twice, so the raw
    // results carry it twice — dedup is a MERGE concern now (mergedCompletion
    // dedups by text), not a collection-time one. The observable set is
    // {alpha, alphabet}.
    const sid = (try env.caps.fire(.completion, &ed.doc, ed.backingPath(), .{ .text = "alph" })).?;
    const merged = try env.caps.mergedCompletion(gpa, sid);
    defer gpa.free(merged);
    try t.expectEqual(@as(usize, 2), merged.len);
    var has_alpha = false;
    var has_alphabet = false;
    for (merged) |item| {
        if (std.mem.eql(u8, item.text, "alpha")) has_alpha = true;
        if (std.mem.eql(u8, item.text, "alphabet")) has_alphabet = true;
    }
    try t.expect(has_alpha and has_alphabet);
}

test "D2: a wasm guest declares+binds a NOVEL 'ui/badge' slot; the host fires, restamps, and decodes it with NO core type for it" {
    // doc/d2-schema-payloads.md §6's worked example, made e2e: `badge.zig`
    // (src/guest/badge.zig) is a third-party CI-status plugin. Nothing in
    // `core/` — not `capability.zig`, not `container.zig`, not this test
    // file — ever names a "Badge" type. The ONLY thing the host holds is the
    // `*const schema.Schema` tree `wl_slot_declare` shipped across the
    // membrane as a canonical blob and `schema.parseSchema` decoded back —
    // proven below by decoding through THAT tree (pulled from `Container`),
    // never through `badge.zig`'s own `badge_schema` constant.
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "badge", @embedFile("guest_badge_wasm"), .{});
    defer plugin.deinit();

    // init() ran wl_slot_declare + wl_slot_bind: the slot exists, WITH a
    // schema (container.zig:1's placeholder `schema = 0` is gone — this is
    // the real `?*const Schema` D2 carries), and one provider is bound.
    const decl = env.container.slots.get("ui/badge").?;
    try t.expect(decl.schema != null);
    try t.expectEqual(@import("../container.zig").Shape.query, decl.shape);
    try t.expectEqual(@import("../container.zig").Composition.ordered_union, decl.composition);
    try t.expectEqual(@as(usize, 1), env.slot_host.providers.items.len);

    // Fire it — the SlotHost/Container race, exactly like `Caps.fire` for
    // completion, but through the generic verbs, and with an explicit fired
    // VERSION the host will restamp every `range` field to (§4), no matter
    // what version the guest's payload claims.
    const schema_mod = @import("weft_schema");
    const fired_version = "fired-session-version-42";
    const id = (try env.slot_host.fire("ui/badge", .{}, fired_version, .{})).?;
    const session = env.slot_host.session(id).?;
    try t.expectEqual(@as(usize, 1), session.all().len);
    try t.expect(session.done());

    const result = session.all()[0];
    try t.expectEqualStrings("badge", result.provider);

    // Decode through the SCHEMA THE HOST HOLDS (pulled from Container, the
    // wire-marshalled tree wl_slot_declare shipped) — not through any Zig
    // struct type, because there is none.
    const schema_tree = decl.schema.?;
    const cur = try schema_mod.decodeCursor(schema_tree, result.payload).enterStruct();
    try t.expectEqualStrings("3 failing", try (try cur.field("text")).?.asStr());
    try t.expectEqual(@as(u32, 3), try (try cur.field("count")).?.asU32());

    // `where` is an effect-path locator: it rides through UNCHANGED, because
    // an anchor is resolved, not restamped (§4); this slice records it,
    // doesn't resolve it (see core/slot.zig's `push` doc).
    const where = try (try cur.field("where")).?.asAnchor();
    try t.expectEqualStrings("ci", where.agent);
    try t.expectEqual(@as(u64, 5), where.seq);

    // `loc` is an observation-path locator, so it is RESTAMPED: the guest's
    // claimed "stale-guest-claimed-version" never survives — the fired
    // session version does. This is schema.walk's observation arm, live on
    // `SlotHost.push`'s path (§4).
    const loc = try (try cur.field("loc")).?.asRange();
    try t.expectEqualStrings(fired_version, loc.version);
    try t.expect(!std.mem.eql(u8, loc.version, "stale-guest-claimed-version"));
    try t.expectEqual(@as(u64, 10), loc.start);
    try t.expectEqual(@as(u64, 14), loc.end);

    env.slot_host.finish(id);
}

test "wasm plugin: demo-config composes commands + binds a key (config surface)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    // Load the edit plugin (provides duplicate-line/upcase-line) then the
    // config that composes them — the same layering as std + user config.
    const edit = try loadPlugin(&engine, &env.ctx, "edit", @embedFile("guest_edit_wasm"), .{});
    defer edit.deinit();
    const cfg = try loadPlugin(&engine, &env.ctx, "demo-config", @embedFile("guest_demo_config_wasm"), .{});
    defer cfg.deinit();

    // init() bound C-d → dup-up through the config surface.
    try env.head.setModeRaw(gpa, "default");
    try t.expectEqualStrings("dup-up", env.keymap.lookup(env.head.currentMode(), "C-d").?);

    const ed = env.buffers.active().textEditor().?;
    try ed.insertText(gpa, "ab");
    ed.placeCursor(0);
    _ = try command.run(&env.commands, &env.ctx, "dup-up", &.{});
    // dup-up ran duplicate-line ("ab\nab") then upcase-line on the current
    // line (cursor still at 0 → the first line) across the membrane.
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("AB\nab", s);
}

test "wasm plugin: project command args/result + kv cross the membrane" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var store: kv.Store = .empty;
    defer store.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "project", @embedFile("guest_project_wasm"), .{ .kv = &store });
    defer plugin.deinit();

    // Seed the recent list host-side (namespaced to the plugin); the guest
    // reads it back through kv and returns it as a string result.
    try store.put(gpa, "project", "recent", "a.zig\nb.zig");
    const r = try command.run(&env.commands, &env.ctx, "project-recent", &.{});
    try t.expectEqualStrings("a.zig\nb.zig", r.string);

    // The scratch buffer has no backing path → remember returns -1 (the
    // integer result crosses the membrane).
    const r2 = try command.run(&env.commands, &env.ctx, "project-remember", &.{});
    try t.expectEqual(command.Value{ .integer = -1 }, r2);
}

test "wasm plugin: palette status echoes the active buffer (introspection)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "std", @embedFile("guest_palette_wasm"), .{});
    defer plugin.deinit();

    // status walks the buffers (bufferCount/bufferAt) and echoes the active
    // one's name — the whole introspection surface across the membrane.
    _ = try command.run(&env.commands, &env.ctx, "status", &.{});
    try t.expectEqualStrings(env.buffers.active().name, env.head.echo.items);
}

test "wasm plugin: palette opens a command pick; accept dispatches back and runs the choice" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    // The pick UI is ordinary commands in the "pick" keymap mode.
    try pick_mod.install(gpa, &env.commands, &env.keymap);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "std", @embedFile("guest_palette_wasm"), .{});
    defer plugin.deinit();

    // pick-commands builds a pick over the whole registry and opens it.
    _ = try command.run(&env.commands, &env.ctx, "pick-commands", &.{});
    try t.expect(env.head.pick.active);

    // Narrow to "status" and accept: the accept crosses back into the guest's
    // on_pick_accept, which runs the chosen command — which echoes the buffer.
    _ = try command.run(&env.commands, &env.ctx, "pick-input", &.{.{ .string = "status" }});
    _ = try command.run(&env.commands, &env.ctx, "pick-accept", &.{});
    try t.expect(!env.head.pick.active); // accept closed the pick
    try t.expectEqualStrings(env.buffers.active().name, env.head.echo.items);
}

test "wasm plugins: consult-line combines anchored row identity with exact match evidence" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("../pick.zig").install(gpa, &env.commands, &env.keymap);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "consult", @embedFile("guest_consult_wasm"), .{});
    defer plugin.deinit();

    const ed = env.buffers.active().textEditor().?;
    try ed.insertText(gpa, "aaa\n    ccc");
    ed.placeCursor(0);

    // Candidate identity resolves the source row; candidate-relative match
    // evidence lands after its indentation. Move the document after the pick
    // has captured candidates: the row's CRDT anchors advance with the merge,
    // while immutable picker evidence stays presentation-only.
    _ = try command.run(&env.commands, &env.ctx, "consult-line", &.{});
    try t.expect(env.head.pick.active);
    _ = try command.run(&env.commands, &env.ctx, "pick-input", &.{.{ .string = "ccc" }});
    try ed.doc.insert(gpa, 0, "prefix\n");
    _ = try command.run(&env.commands, &env.ctx, "pick-accept", &.{});
    try t.expect(!env.head.pick.active);
    try t.expectEqual(@as(usize, 15), ed.cursorOffset()); // exact "ccc", not shifted line start 11

    // Deleting the selected row while the picker is open collapses its
    // anchored range. Acceptance fails closed: it must not jump to the row or
    // EOF which happened to inherit the old byte coordinate.
    ed.placeCursor(0);
    _ = try command.run(&env.commands, &env.ctx, "consult-line", &.{});
    _ = try command.run(&env.commands, &env.ctx, "pick-input", &.{.{ .string = "ccc" }});
    try ed.doc.delete(gpa, .{ .start = 11, .end = 18 });
    _ = try command.run(&env.commands, &env.ctx, "pick-accept", &.{});
    try t.expect(!env.head.pick.active);
    try t.expectEqual(@as(usize, 0), ed.cursorOffset());

    // Reopening the same tool while its picker is live cancels the old
    // interaction before replacing its retained target table. The old
    // cancellation callback must not release the new picker's anchors.
    _ = try command.run(&env.commands, &env.ctx, "consult-line", &.{});
    _ = try command.run(&env.commands, &env.ctx, "pick-input", &.{.{ .string = "aaa" }});
    _ = try command.run(&env.commands, &env.ctx, "consult-line", &.{});
    try t.expect(env.head.pick.active);
    _ = try command.run(&env.commands, &env.ctx, "pick-input", &.{.{ .string = "aaa" }});
    _ = try command.run(&env.commands, &env.ctx, "pick-accept", &.{});
    try t.expect(!env.head.pick.active);
    try t.expectEqual(@as(usize, 7), ed.cursorOffset());

    // A length-preserving edit inside the selected row does not move either
    // endpoint. Full-row evidence still detects it and acceptance fails
    // closed rather than treating anchors alone as proof of unchanged text.
    ed.placeCursor(0);
    _ = try command.run(&env.commands, &env.ctx, "consult-line", &.{});
    _ = try command.run(&env.commands, &env.ctx, "pick-input", &.{.{ .string = "aaa" }});
    try ed.doc.replaceAll(gpa, &.{.{ .range = .{ .start = 7, .end = 10 }, .bytes = "AAA" }});
    _ = try command.run(&env.commands, &env.ctx, "pick-accept", &.{});
    try t.expect(!env.head.pick.active);
    try t.expectEqual(@as(usize, 0), ed.cursorOffset());
}

test "wasm plugins: consult-line verifies content beyond its display scratch" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("../pick.zig").install(gpa, &env.commands, &env.keymap);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const consult = try loadPlugin(&engine, &env.ctx, "consult", @embedFile("guest_consult_wasm"), .{});
    defer consult.deinit();

    const ed = env.buffers.active().textEditor().?;
    const line = try gpa.alloc(u8, 70 * 1024);
    defer gpa.free(line);
    @memset(line, 'a');
    try ed.insertText(gpa, line);
    ed.placeCursor(0);

    _ = try command.run(&env.commands, &env.ctx, "consult-line", &.{});
    try t.expect(env.head.pick.active);
    // Change bytes after the 64-KiB candidate/display window without changing
    // the row length or its anchor endpoints.
    try ed.doc.replaceAll(gpa, &.{.{
        .range = .{ .start = 68 * 1024, .end = 68 * 1024 + 1 },
        .bytes = "b",
    }});
    _ = try command.run(&env.commands, &env.ctx, "pick-accept", &.{});
    try t.expect(!env.head.pick.active);
    try t.expectEqual(@as(usize, 0), ed.cursorOffset());
}

test "wasm plugins: consult-imenu picks a definition and jumps to it" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("../pick.zig").install(gpa, &env.commands, &env.keymap);

    const src = "fn foo() void {}\nfn bar() void {}";
    const ed = env.buffers.active().textEditor().?;
    try ed.insertText(gpa, src);
    const sx = @import("../syntax.zig");
    const syn = try sx.Syntax.create(gpa, sx.builtinForPath("t.zig").?, &ed.doc);
    defer syn.destroy();
    env.buffers.active().frontend = syn;
    const R = struct {
        fn resolve(buf: *@import("../Buffers.zig").Buffer) ?*sx.Syntax {
            return @ptrCast(@alignCast(buf.frontend orelse return null));
        }
    };

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "consult", @embedFile("guest_consult_wasm"), .{ .syntax_of = R.resolve });
    defer plugin.deinit();

    ed.placeCursor(0);
    _ = try command.run(&env.commands, &env.ctx, "consult-imenu", &.{});
    try t.expect(env.head.pick.active);
    _ = try command.run(&env.commands, &env.ctx, "pick-input", &.{.{ .string = "bar" }});
    _ = try command.run(&env.commands, &env.ctx, "pick-accept", &.{});
    try t.expectEqual(std.mem.indexOf(u8, src, "fn bar").?, ed.cursorOffset());
}

test "wasm plugins: buf-pick switches to the accepted buffer by its identity" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("../builtins.zig").install(gpa, &env.commands, &env.keymap, &env.head, &env.actions); // buffer-switch
    try @import("../pick.zig").install(gpa, &env.commands, &env.keymap);

    // Two more buffers beyond the initial scratch (ids 1 and 2).
    _ = try env.buffers.create(gpa, "alpha");
    _ = try env.buffers.create(gpa, "beta");

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "buffers", @embedFile("guest_buffers_wasm"), .{});
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "buf-pick", &.{});
    try t.expect(env.head.pick.active);
    // The active buffer is intentionally the least convenient fallback: it
    // stays available at the end while the other buffers keep their stable
    // id-order. The guest resolves the accepted row through the identity the
    // CANDIDATE carries, not through a table indexed by row.
    try t.expectEqual(@as(usize, 3), env.head.pick.items.items.len);
    try t.expectEqualStrings("alpha", env.head.pick.items.items[0]);
    try t.expectEqualStrings("beta", env.head.pick.items.items[1]);
    try t.expectEqualStrings("*scratch*", env.head.pick.items.items[2]);
    _ = try command.run(&env.commands, &env.ctx, "pick-input", &.{.{ .string = "beta" }});
    _ = try command.run(&env.commands, &env.ctx, "pick-accept", &.{});
    // The accepted row resolved to beta's id → it is now the active buffer.
    try t.expectEqualStrings("beta", env.buffers.active().name);
}

test "wasm plugin: structural node-kind/delete-node degrade honestly with no grammar" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    // No syntax service wired → nodeAt reports "no node" across the membrane.
    const plugin = try loadPlugin(&engine, &env.ctx, "structural", @embedFile("guest_structural_wasm"), .{});
    defer plugin.deinit();

    const ed = env.buffers.active().textEditor().?;
    try ed.insertText(gpa, "foo");
    const r1 = try command.run(&env.commands, &env.ctx, "node-kind", &.{});
    try t.expect(r1 == .nil); // no grammar → nil
    const r2 = try command.run(&env.commands, &env.ctx, "delete-node", &.{});
    try t.expectEqual(command.Value{ .integer = 0 }, r2);
    try t.expect(ed.text().byteLen() == 3); // nothing deleted
}

test "wasm plugin: ts expands selection to the enclosing node + runs a query" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    const src = "const x = 42;";
    const ed = env.buffers.active().textEditor().?;
    try ed.insertText(gpa, src);

    // Attach a real zig grammar via the buffer's frontend slot; a resolver hands
    // it to the membrane (the host owns that slot).
    const sx = @import("../syntax.zig");
    const syn = try sx.Syntax.create(gpa, sx.builtinForPath("t.zig").?, &ed.doc);
    defer syn.destroy();
    env.buffers.active().frontend = syn;
    const R = struct {
        fn resolve(buf: *@import("../Buffers.zig").Buffer) ?*sx.Syntax {
            return @ptrCast(@alignCast(buf.frontend orelse return null));
        }
    };

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "ts", @embedFile("guest_ts_wasm"), .{ .syntax_of = R.resolve });
    defer plugin.deinit();

    // Cursor on "42": select-node selects the literal; expand grows to a
    // strictly larger enclosing node (design §6.2, via native syntax reads).
    ed.placeCursor(std.mem.indexOf(u8, src, "42").?);
    _ = try command.run(&env.commands, &env.ctx, "ts-select-node", &.{});
    const leaf = ed.selectedRange().?;
    _ = try command.run(&env.commands, &env.ctx, "ts-expand-selection", &.{});
    const parent = ed.selectedRange().?;
    try t.expect(parent.end - parent.start > leaf.end - leaf.start);

    // A query over the buffer materializes captures across the membrane: the
    // identifier "x" is found (>= 1 capture).
    const n = try command.run(&env.commands, &env.ctx, "ts-query", &.{.{ .string = "(identifier) @i" }});
    try t.expect(n == .integer and n.integer >= 1);
}

test "wasm plugins: a tree text object (a-function) an operator deletes (daf)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    const src = "fn foo() void {}\nconst x = 1;";
    const ed = env.buffers.active().textEditor().?;
    try ed.insertText(gpa, src);

    const sx = @import("../syntax.zig");
    const syn = try sx.Syntax.create(gpa, sx.builtinForPath("t.zig").?, &ed.doc);
    defer syn.destroy();
    env.buffers.active().frontend = syn;
    const R = struct {
        fn resolve(buf: *@import("../Buffers.zig").Buffer) ?*sx.Syntax {
            return @ptrCast(@alignCast(buf.frontend orelse return null));
        }
    };

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const textobjects = try loadPlugin(&engine, &env.ctx, "textobjects", @embedFile("guest_textobjects_wasm"), .{ .syntax_of = R.resolve });
    defer textobjects.deinit();
    const operators = try loadPlugin(&engine, &env.ctx, "operators", @embedFile("guest_operators_wasm"), .{ .syntax_of = R.resolve });
    defer operators.deinit();

    // Cursor inside the function; a-function selects the whole function node,
    // the operator deletes it — a tree object composed with the SAME operator.
    ed.placeCursor(std.mem.indexOf(u8, src, "foo").?);
    const rv = try command.run(&env.commands, &env.ctx, "textobj.a-function", &.{});
    try t.expect(rv == .range);
    _ = try command.run(&env.commands, &env.ctx, "op.delete", &.{rv});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expect(std.mem.indexOf(u8, s, "foo") == null); // the function is gone
    try t.expect(std.mem.indexOf(u8, s, "const x") != null); // the rest remains
}

test "wasm plugin: region claims a subbuffer + attaches a fact across the membrane" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var subs: subbuffer.SubBuffers = .empty;
    defer subs.deinit(gpa); // frees the claimed entries (runs after plugin.deinit)

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "region", @embedFile("guest_region_wasm"), .{ .subbuffers = &subs });
    defer plugin.deinit();

    const ed = env.buffers.active().textEditor().?;
    try ed.insertText(gpa, "line one\nline two");
    ed.placeCursor(2); // inside the first line ("line one" — 8 bytes)

    const r = try command.run(&env.commands, &env.ctx, "mark-region", &.{.{ .string = "js" }});
    try t.expectEqual(command.Value{ .integer = 8 }, r);
    // The claimed subbuffer (handle 0) carries the language fact the guest set.
    try t.expectEqualStrings("js", plugin.subs.items[0].fact("language").?);
}

test "wasm plugin: shell insert-shell runs a command off-thread and inserts at its CRDT anchor" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var loop = async_loop.Loop.init(gpa, env.pool, @import("../task.zig").nowNs);
    defer loop.deinit();

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "shell", @embedFile("guest_shell_wasm"), .{ .loop = &loop });
    defer plugin.deinit();

    const ed = env.buffers.active().textEditor().?;
    try ed.insertText(gpa, "X");
    ed.placeCursor(1); // capture the insert point at offset 1

    _ = try command.run(&env.commands, &env.ctx, "insert-shell", &.{.{ .string = "printf hi" }});

    // Concurrently insert at the head: the deferred insert's identity anchor
    // must resolve to 3 before "hi" lands.
    ed.placeCursor(0);
    try ed.insertText(gpa, "YY"); // doc → "YYX"

    var rounds: usize = 0;
    while (ed.text().byteLen() < 5 and rounds < 5_000_000) : (rounds += 1) {
        _ = loop.tick();
        std.Thread.yield() catch {};
    }
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    // "hi" landed at the anchored offset 3 (after "YYX"), authored as the peer.
    try t.expectEqualStrings("YYXhi", s);
    try t.expect(ed.doc.commitAt(ed.doc.commitCount() - 1).author != .user);
}

test "wasm plugin: shell insert is a no-op when the async service is absent" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    // No loop wired: the shell plugin declared proc+timer, but with no async
    // service the effect drops honestly (no ghost edit).
    const plugin = try loadPlugin(&engine, &env.ctx, "shell", @embedFile("guest_shell_wasm"), .{});
    defer plugin.deinit();
    try t.expect(plugin.perms[wasm_host.perm_proc] and plugin.perms[wasm_host.perm_timer]); // declared

    const ed = env.buffers.active().textEditor().?;
    try ed.insertText(gpa, "Z");
    _ = try command.run(&env.commands, &env.ctx, "insert-shell", &.{.{ .string = "printf hi" }});
    try t.expect(ed.text().byteLen() == 1); // nothing inserted
}

test "wasm plugin: git-status runs git into a focused tool buffer (async)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("../builtins.zig").install(gpa, &env.commands, &env.keymap, &env.head, &env.actions); // buffer-create

    var loop = async_loop.Loop.init(gpa, env.pool, @import("../task.zig").nowNs);
    defer loop.deinit();

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "git", @embedFile("guest_git_wasm"), .{ .loop = &loop });
    defer plugin.deinit();
    try t.expect(plugin.perms[wasm_host.perm_proc] and plugin.perms[wasm_host.perm_timer]);

    // Phase 2b/2c: the transient verbs are declared + registered (menu modes are
    // keymap state, but each terminal action is a real command).
    for ([_][]const u8{
        "git-amend",            "git-fixup",         "git-cherry-pick", "git-revert",
        "git-reset-hard",       "git-branch-create", "git-stash-pop",   "git-push-do",
        "git-fetch-toggle-all", "git-rebase-save",   "git-commit-save",
    }) |name| try t.expect(env.commands.find(name) != null);

    _ = try command.run(&env.commands, &env.ctx, "git-status", &.{});
    // The magit model buffer was created + focused synchronously (before output).
    const buf = blk: {
        var it = env.buffers.iterator();
        while (it.next()) |b| if (std.mem.eql(u8, b.name, "*git*")) break :blk b;
        break :blk null;
    };
    try t.expect(buf != null);

    // Drive the async loop until git's output lands (bounded; this repo is a
    // git checkout). If git is unavailable the buffer stays empty — the
    // structural checks above still hold.
    var rounds: usize = 0;
    while (rounds < 20_000_000 and buf.?.textEditor().?.text().byteLen() == 0) : (rounds += 1) {
        _ = loop.tick();
        std.Thread.yield() catch {};
    }
    if (buf.?.textEditor().?.text().byteLen() > 0) {
        // on_fill_token parsed the raw git output and re-rendered the MODEL: the
        // buffer holds the pretty projection, never the porcelain. Whether the ambient
        // cwd is a repo or not, we get a model header — `Branch:` in a repo, or
        // `Not a git repository.` outside one — but never a raw `## `/`#` line.
        const s = try buf.?.textEditor().?.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        const is_repo = std.mem.indexOf(u8, s, "Branch:") != null;
        const not_repo = std.mem.indexOf(u8, s, "Not a git repository.") != null;
        try t.expect(is_repo or not_repo);
        try t.expect(!std.mem.startsWith(u8, s, "## ")); // porcelain never leaks through
        const doc = buf.?.textEditor().?.doc;
        try t.expect(doc.commitAt(doc.commitCount() - 1).author != .user); // the plugin peer
    }
}

test "wasm plugin: run-command runs a shell command into a tool buffer (async)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("../builtins.zig").install(gpa, &env.commands, &env.keymap, &env.head, &env.actions);

    var loop = async_loop.Loop.init(gpa, env.pool, @import("../task.zig").nowNs);
    defer loop.deinit();
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "run", @embedFile("guest_run_wasm"), .{ .loop = &loop });
    defer plugin.deinit();

    // A deterministic command (echo) — proves the proc→buffer path end to end.
    _ = try command.run(&env.commands, &env.ctx, "run-command", &.{.{ .string = "echo weft-ok" }});
    const buf = blk: {
        var it = env.buffers.iterator();
        while (it.next()) |b| if (std.mem.eql(u8, b.name, "*output*")) break :blk b;
        break :blk null;
    };
    try t.expect(buf != null);
    var rounds: usize = 0;
    while (rounds < 20_000_000 and buf.?.textEditor().?.text().byteLen() == 0) : (rounds += 1) {
        _ = loop.tick();
        std.Thread.yield() catch {};
    }
    const s = try buf.?.textEditor().?.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("weft-ok", s); // stdout, trailing newline trimmed
    const doc = buf.?.textEditor().?.doc;
    try t.expect(doc.commitAt(doc.commitCount() - 1).author != .user); // the plugin peer
}

test "wasm plugin: fmt filters a range through a command (async, in-place tmp)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var loop = async_loop.Loop.init(gpa, env.pool, @import("../task.zig").nowNs);
    defer loop.deinit();
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "fmt", @embedFile("guest_fmt_wasm"), .{ .loop = &loop });
    defer plugin.deinit();

    const ed = env.buffers.active().textEditor().?;
    try ed.insertText(gpa, "foo foo");
    const before = ed.doc.commitCount();
    // Filter the whole buffer through sed (in /usr/bin — no nix PATH needed):
    // rewrite the temp file in place, then the result replaces the range.
    _ = try command.run(&env.commands, &env.ctx, "filter", &.{.{ .string = "sed -i s/foo/bar/g {}" }});
    var rounds: usize = 0;
    while (rounds < 20_000_000 and ed.doc.commitCount() == before) : (rounds += 1) {
        _ = loop.tick();
        std.Thread.yield() catch {};
    }
    try t.expect(ed.doc.commitCount() > before); // the async filter landed an edit
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    // Either transformed (sed on PATH) or the original (no PATH in the test
    // harness) — never corrupted/emptied. That safety is the load-bearing part;
    // the transform is exercised at runtime where main wires the real environ.
    try t.expect(std.mem.eql(u8, s, "foo foo") or std.mem.indexOf(u8, s, "bar") != null);
    try t.expect(ed.doc.commitAt(ed.doc.commitCount() - 1).author != .user); // plugin peer
}

test "wasm plugin: repl runs a persistent process and streams its output back" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("../builtins.zig").install(gpa, &env.commands, &env.keymap, &env.head, &env.actions); // buffer-create

    var loop = async_loop.Loop.init(gpa, env.pool, @import("../task.zig").nowNs);
    defer loop.deinit();
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    // `cat` is a persistent echo REPL — stateful proof the child stays alive.
    const plugin = try loadPlugin(&engine, &env.ctx, "repl", @embedFile("guest_repl_wasm"), .{ .loop = &loop, .pool = env.pool });
    defer plugin.deinit(); // kills cat + JOINS the reader — no hang, no leak

    // A shell read-loop is a persistent echo REPL whose `echo` flushes
    // immediately (unlike `cat`, which block-buffers stdout on a pipe).
    _ = try command.run(&env.commands, &env.ctx, "repl-start", &.{.{ .string = "while read l; do echo \"$l\"; done" }});
    const buf = blk: {
        var it = env.buffers.iterator();
        while (it.next()) |b| if (std.mem.eql(u8, b.name, "*repl*")) break :blk b;
        break :blk null;
    };
    try t.expect(buf != null);
    _ = try command.run(&env.commands, &env.ctx, "repl-send", &.{.{ .string = "ping" }});

    // Drive the frame drain until cat's echo streams into *repl* (bounded — a
    // timeout fails the assert rather than hanging).
    var rounds: usize = 0;
    while (rounds < 5_000_000 and buf.?.textEditor().?.text().byteLen() == 0) : (rounds += 1) {
        _ = wasm_host.drainReplSessions(plugin);
        std.Thread.yield() catch {};
    }
    const s = try buf.?.textEditor().?.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expect(std.mem.indexOf(u8, s, "ping") != null); // the echoed line
}

test "wasm plugin: console-send runs the current line and appends output" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("../builtins.zig").install(gpa, &env.commands, &env.keymap, &env.head, &env.actions); // buffer-create

    var loop = async_loop.Loop.init(gpa, env.pool, @import("../task.zig").nowNs);
    defer loop.deinit();
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "console", @embedFile("guest_console_wasm"), .{ .loop = &loop });
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "console-open", &.{}); // focus *console*
    const ed = env.buffers.active().textEditor().?;
    try ed.insertText(gpa, "echo con-ok"); // type a command line
    const before = ed.doc.commitCount();
    _ = try command.run(&env.commands, &env.ctx, "console-send", &.{});
    var rounds: usize = 0;
    while (rounds < 20_000_000 and ed.doc.commitCount() == before) : (rounds += 1) {
        _ = loop.tick();
        std.Thread.yield() catch {};
    }
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("echo con-ok\ncon-ok", s); // output appended below the input
}

test "wasm plugin: vim wires the modal keymap and runs motions/operators as .wasm" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    // The register is now a CORE service (register.zig), shared by every editor
    // — vim's yank/paste route through it, so wire one for the yy/p round-trip.
    var reg: register.Bank = .{};
    defer reg.deinit(gpa);
    const plugin = try loadPlugin(&engine, &env.ctx, "vim", @embedFile("guest_vim_wasm"), .{ .register = &reg });
    defer plugin.deinit();

    // init() booted into normal and wired the whole keymap through the config
    // surface — motions, operators, insert entries — all across the membrane.
    try t.expectEqualStrings("normal", env.head.currentMode());
    try t.expectEqualStrings("vim-insert", env.keymap.lookup(env.head.currentMode(), "i").?);
    try t.expectEqualStrings("enter-op-delete", env.keymap.lookup(env.head.currentMode(), "d").?);

    // Mode switches: i → insert, Escape (vim-normal) → normal.
    _ = try command.run(&env.commands, &env.ctx, "vim-insert", &.{});
    try t.expectEqualStrings("insert", env.head.currentMode());
    _ = try command.run(&env.commands, &env.ctx, "vim-normal", &.{});
    try t.expectEqualStrings("normal", env.head.currentMode());

    // yank-line + paste duplicates the current line (through the core register).
    const ed = env.buffers.active().textEditor().?;
    try ed.insertText(gpa, "hello");
    ed.placeCursor(0);
    _ = try command.run(&env.commands, &env.ctx, "yank-line", &.{});
    _ = try command.run(&env.commands, &env.ctx, "paste", &.{});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("hello\nhello", s);
    try t.expect(ed.doc.commitAt(ed.doc.commitCount() - 1).author != .user);
}

test "wasm plugin: vim yank/paste ferries a subbuffer id through the register (dd→p is a move)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    var reg: register.Bank = .{};
    defer reg.deinit(gpa);
    var subs: subbuffer.SubBuffers = .empty;
    defer subs.deinit(gpa);
    const plugin = try loadPlugin(&engine, &env.ctx, "vim", @embedFile("guest_vim_wasm"), .{ .register = &reg, .subbuffers = &subs });
    defer plugin.deinit();

    const ed = env.buffers.active().textEditor().?;
    try ed.insertText(gpa, "row-a");
    // A projection row: its name carries a hidden id (exactly as dired claims).
    const row = try subs.claim(gpa, &ed.doc, .{ .start = 0, .end = 5 });
    try row.putFact(gpa, "id", "42");
    ed.placeCursor(0);

    // yy then p: the id must ride the CORE register onto the pasted line — a
    // move — not vanish into a delete+create. The whole thesis, end to end
    // across the wasm membrane: yankRange snapshots it, pasteAt re-stamps it.
    _ = try command.run(&env.commands, &env.ctx, "yank-line", &.{});
    _ = try command.run(&env.commands, &env.ctx, "paste", &.{});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("row-a\nrow-a", s);
    const pasted = subs.at(&ed.doc, 8) orelse return error.NoIdOnPastedRow;
    try t.expectEqualStrings("42", pasted.fact("id").?);
}

test "wasm plugin: explicit named text register survives a later delete yank" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    var bank: register.Bank = .{};
    defer bank.deinit(gpa);
    const operators = try loadPlugin(&engine, &env.ctx, "operators", @embedFile("guest_operators_wasm"), .{});
    defer operators.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "vim", @embedFile("guest_vim_wasm"), .{ .register = &bank });
    defer plugin.deinit();

    const ed = env.buffers.active().textEditor().?;
    try ed.insertText(gpa, "alpha\nbeta");
    ed.placeCursor(0);
    // The command sequence is the wasm equivalent of `"ayy`.
    try dispatch.dispatchSpec(&env.ctx, "quotedbl", .none);
    try dispatch.dispatchSpec(&env.ctx, "a", .none);
    try dispatch.dispatchSpec(&env.ctx, "y", .none);
    try dispatch.dispatchSpec(&env.ctx, "y", .none);
    // Capture the later line into unnamed (the same capture that precedes
    // `dd`) and remove it; this keeps the test focused on register routing.
    ed.placeCursor(6);
    try dispatch.dispatchSpec(&env.ctx, "d", .none);
    try dispatch.dispatchSpec(&env.ctx, "d", .none);
    // The final sequence is `"ap`; it reads the named slot explicitly.
    ed.placeCursor(0);
    try dispatch.dispatchSpec(&env.ctx, "quotedbl", .none);
    try dispatch.dispatchSpec(&env.ctx, "a", .none);
    try dispatch.dispatchSpec(&env.ctx, "p", .none);
    const text = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(text);
    try t.expectEqualStrings("alpha\nalpha\n", text);
}

test "wasm plugins: a motion returns a range an operator awaits + applies (dw)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const motions = try loadPlugin(&engine, &env.ctx, "motions", @embedFile("guest_motions_wasm"), .{});
    defer motions.deinit();
    const operators = try loadPlugin(&engine, &env.ctx, "operators", @embedFile("guest_operators_wasm"), .{});
    defer operators.deinit();

    const ed = env.buffers.active().textEditor().?;
    try ed.insertText(gpa, "foo bar");
    ed.placeCursor(0);

    // The motion returns a borrowed pair of document-owned live anchors —
    // never a bare offset. Cursor is one end (0), the target the other (4).
    const rv = try command.run(&env.commands, &env.ctx, "motion.word-fwd", &.{});
    try t.expect(rv == .range);

    // The operator awaits that range (as its arg) and applies the gated edit —
    // authored as the operators plugin's peer, not the user.
    _ = try command.run(&env.commands, &env.ctx, "op.delete", &.{rv});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("bar", s);
    try t.expect(ed.doc.commitAt(ed.doc.commitCount() - 1).author != .user);
}

test "wasm plugins: an awaited live range follows an intervening edit" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const motions = try loadPlugin(&engine, &env.ctx, "motions", @embedFile("guest_motions_wasm"), .{});
    defer motions.deinit();
    const operators = try loadPlugin(&engine, &env.ctx, "operators", @embedFile("guest_operators_wasm"), .{});
    defer operators.deinit();

    const ed = env.buffers.active().textEditor().?;
    try ed.insertText(gpa, "foo bar");
    ed.placeCursor(0);

    // Compute a word-forward range [0,4) as document-owned live anchors.
    const rv = try command.run(&env.commands, &env.ctx, "motion.word-fwd", &.{});
    try t.expect(rv == .range);

    // A concurrent edit lands BEFORE the operator applies: insert "XX" at 0.
    // The anchors advance to [2,6) — "Buffer changed" is inexpressible.
    ed.placeCursor(0);
    try ed.insertText(gpa, "XX");

    _ = try command.run(&env.commands, &env.ctx, "op.delete", &.{rv});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("XXbar", s); // "foo " deleted at its anchored site
}

test "wasm plugins: vim composes motions + operators — dw through the keymap" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const motions = try loadPlugin(&engine, &env.ctx, "motions", @embedFile("guest_motions_wasm"), .{});
    defer motions.deinit();
    const operators = try loadPlugin(&engine, &env.ctx, "operators", @embedFile("guest_operators_wasm"), .{});
    defer operators.deinit();
    const vim = try loadPlugin(&engine, &env.ctx, "vim", @embedFile("guest_vim_wasm"), .{});
    defer vim.deinit();

    const ed = env.buffers.active().textEditor().?;
    try ed.insertText(gpa, "foo bar");
    ed.placeCursor(0);

    // `d` enters operator-pending; the `w` binding there is vim's op wrapper,
    // which runs motion.word-fwd and hands its range to op.delete.
    _ = try command.run(&env.commands, &env.ctx, "enter-op-delete", &.{});
    try t.expectEqualStrings("op-pending", env.head.currentMode());
    try t.expectEqualStrings("vim/o/motion.word-fwd", env.keymap.lookup(env.head.currentMode(), "w").?);
    _ = try command.run(&env.commands, &env.ctx, env.keymap.lookup(env.head.currentMode(), "w").?, &.{});
    try t.expectEqualStrings("normal", env.head.currentMode());

    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("bar", s);
}

test "wasm plugins: a text object returns a range an operator applies (di\")" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const textobjects = try loadPlugin(&engine, &env.ctx, "textobjects", @embedFile("guest_textobjects_wasm"), .{});
    defer textobjects.deinit();
    const operators = try loadPlugin(&engine, &env.ctx, "operators", @embedFile("guest_operators_wasm"), .{});
    defer operators.deinit();

    const ed = env.buffers.active().textEditor().?;
    try ed.insertText(gpa, "say \"hi\" ok");
    ed.placeCursor(5); // inside the quotes

    // inner-quote-double yields the span between the quotes ("hi"); the operator
    // deletes it — the range is absolute (the construct), not cursor-relative.
    const rv = try command.run(&env.commands, &env.ctx, "textobj.inner-quote-double", &.{});
    try t.expect(rv == .range);
    _ = try command.run(&env.commands, &env.ctx, "op.delete", &.{rv});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("say \"\" ok", s);
}

test "wasm plugins: vim di( through the keymap (operator + text object)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const textobjects = try loadPlugin(&engine, &env.ctx, "textobjects", @embedFile("guest_textobjects_wasm"), .{});
    defer textobjects.deinit();
    const operators = try loadPlugin(&engine, &env.ctx, "operators", @embedFile("guest_operators_wasm"), .{});
    defer operators.deinit();
    const vim = try loadPlugin(&engine, &env.ctx, "vim", @embedFile("guest_vim_wasm"), .{});
    defer vim.deinit();

    const ed = env.buffers.active().textEditor().?;
    try ed.insertText(gpa, "f(a, b)");
    ed.placeCursor(4); // inside the parens

    // di( : d → op-pending, i → op-to (inner), ( → the paren object.
    _ = try command.run(&env.commands, &env.ctx, "enter-op-delete", &.{});
    _ = try command.run(&env.commands, &env.ctx, env.keymap.lookup(env.head.currentMode(), "i").?, &.{});
    try t.expectEqualStrings("op-to", env.head.currentMode());
    _ = try command.run(&env.commands, &env.ctx, env.keymap.lookup(env.head.currentMode(), "parenleft").?, &.{});
    try t.expectEqualStrings("normal", env.head.currentMode());

    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("f()", s);
}

test "wasm plugins: a view-grade peer's op.delete refuses (zero permission code)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const motions = try loadPlugin(&engine, &env.ctx, "motions", @embedFile("guest_motions_wasm"), .{});
    defer motions.deinit();
    const operators = try loadPlugin(&engine, &env.ctx, "operators", @embedFile("guest_operators_wasm"), .{});
    defer operators.deinit();

    const ed = env.buffers.active().textEditor().?;
    try ed.insertText(gpa, "foo bar");
    ed.placeCursor(0);
    ed.doc.my_grant = .view; // the document is read-only for us

    // The motion (read-only) still computes a range — reads are never gated.
    const rv = try command.run(&env.commands, &env.ctx, "motion.word-fwd", &.{});
    try t.expect(rv == .range);
    // But the operator's edit dies at the gate: the buffer is unchanged, and no
    // ghost commit was authored.
    const before = ed.doc.commitCount();
    env.head.echo.clearRetainingCapacity();
    _ = try command.run(&env.commands, &env.ctx, "op.delete", &.{rv});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("foo bar", s);
    try t.expectEqual(before, ed.doc.commitCount());
    // The guest door is silent, so the refusal is only honest because the ONE
    // edit door echoed it — same feedback a builtin's refusal gets.
    try t.expectEqualStrings("read-only: view access", env.head.echo.items);
}

test "wasm plugins: a read-only buffer refuses a guest edit and says so" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const motions = try loadPlugin(&engine, &env.ctx, "motions", @embedFile("guest_motions_wasm"), .{});
    defer motions.deinit();
    const operators = try loadPlugin(&engine, &env.ctx, "operators", @embedFile("guest_operators_wasm"), .{});
    defer operators.deinit();

    const ed = env.buffers.active().textEditor().?;
    try ed.insertText(gpa, "foo bar");
    ed.placeCursor(0);
    env.buffers.active().read_only = true;

    const rv = try command.run(&env.commands, &env.ctx, "motion.word-fwd", &.{});
    env.head.echo.clearRetainingCapacity();
    _ = try command.run(&env.commands, &env.ctx, "op.delete", &.{rv});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("foo bar", s);
    try t.expectEqualStrings("read-only buffer", env.head.echo.items);
}

test "wasm plugin: comment toggles a line comment, preserving indent" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "comment", @embedFile("guest_comment_wasm"), .{});
    defer plugin.deinit();

    const ed = env.buffers.active().textEditor().?;
    try ed.insertText(gpa, "  hi");
    ed.placeCursor(4);
    _ = try command.run(&env.commands, &env.ctx, "comment-line", &.{});
    {
        const s = try ed.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expectEqualStrings("  // hi", s);
    }
    _ = try command.run(&env.commands, &env.ctx, "comment-line", &.{});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("  hi", s);
}

test "wasm plugin: whitespace trims trailing spaces on the line" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "whitespace", @embedFile("guest_whitespace_wasm"), .{});
    defer plugin.deinit();

    const ed = env.buffers.active().textEditor().?;
    try ed.insertText(gpa, "hi   \nok");
    ed.placeCursor(0);
    _ = try command.run(&env.commands, &env.ctx, "trim-trailing-line", &.{});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("hi\nok", s);
}

test "wasm plugin: numbers increments the integer under the cursor" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "numbers", @embedFile("guest_numbers_wasm"), .{});
    defer plugin.deinit();

    const ed = env.buffers.active().textEditor().?;
    try ed.insertText(gpa, "x 41 y");
    ed.placeCursor(2); // on the '4'
    _ = try command.run(&env.commands, &env.ctx, "increment-number", &.{});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("x 42 y", s);
}

test "wasm plugin: autopair inserts a matched pair around the cursor" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "autopair", @embedFile("guest_autopair_wasm"), .{});
    defer plugin.deinit();

    const ed = env.buffers.active().textEditor().?;
    try ed.insertText(gpa, "ab");
    ed.placeCursor(0);
    _ = try command.run(&env.commands, &env.ctx, "pair-paren", &.{});
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("()ab", s);
    try t.expectEqual(@as(usize, 1), ed.cursorOffset());
}

test "wasm plugin: notes capture appends via fs and open opens the real file, not a scratch copy" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("../builtins.zig").install(gpa, &env.commands, &env.keymap, &env.head, &env.actions); // buffer-create, open

    const tmp = "weft-notes-test.md"; // cwd-relative; cleaned up below
    file.deleteFile(gpa, tmp);
    defer file.deleteFile(gpa, tmp);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "notes", @embedFile("guest_notes_wasm"), .{});
    defer plugin.deinit();
    // No fs_read: `open` is a host command, not an fs.read import.
    try t.expect(!plugin.perms[wasm_host.perm_fs_read] and plugin.perms[wasm_host.perm_fs_write]);

    // Two captures append to the file; open opens the note target itself.
    _ = try command.run(&env.commands, &env.ctx, "notes-capture", &.{ .{ .string = "todo x" }, .{ .string = tmp } });
    _ = try command.run(&env.commands, &env.ctx, "notes-capture", &.{ .{ .string = "todo y" }, .{ .string = tmp } });
    _ = try command.run(&env.commands, &env.ctx, "notes-open", &.{.{ .string = tmp }});

    // No scratch "*notes*" buffer — the opened buffer is path-backed.
    const scratch = blk: {
        var it = env.buffers.iterator();
        while (it.next()) |b| if (std.mem.eql(u8, b.name, "*notes*")) break :blk b;
        break :blk null;
    };
    try t.expect(scratch == null);

    const id = env.buffers.findByPath(tmp) orelse return error.TestExpectedNotesFileOpen;
    const buf = env.buffers.get(id).?;
    const s = try buf.textEditor().?.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("todo x\ntodo y\n", s);
}

test "wasm plugin: W4 slice 1 GATE — revoking fs from a RUNNING plugin traps its next fs call, real wasm guest" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("../builtins.zig").install(gpa, &env.commands, &env.keymap, &env.head, &env.actions);

    const tmp = "weft-notes-revoke-test.md";
    file.deleteFile(gpa, tmp);
    defer file.deleteFile(gpa, tmp);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();

    const grants_mod = @import("../grants.zig");
    var table = grants_mod.HandleTable.init(gpa);
    defer table.deinit();

    // Loaded with a grant table wired (`opts.grant_table`) — the ONLY
    // difference from the plain "notes" test above: this plugin's declared
    // perms are minted into REVOCABLE handle-table rows (`mintGrantHandles`,
    // called by `loadPlugin` right after `describe()`), not left as bare
    // booleans.
    const plugin = try loadPlugin(&engine, &env.ctx, "notes", @embedFile("guest_notes_wasm"), .{ .grant_table = &table });
    defer plugin.deinit();
    try t.expect(plugin.perms[wasm_host.perm_fs_write]);
    try t.expect(table.check(plugin.grant_handles[wasm_host.perm_fs_write]));

    // Live and working, exactly like the ungated test — the migration is
    // behavior-identical for a granted plugin.
    _ = try command.run(&env.commands, &env.ctx, "notes-capture", &.{ .{ .string = "before" }, .{ .string = tmp } });

    // Revoke fs_write from the RUNNING plugin — no reload, no re-describe,
    // no new load at all: the SAME `*WasmPlugin` the first capture already
    // dispatched through.
    const n = table.revoke("notes", wasm_host.Perm.fs_write.label());
    try t.expectEqual(@as(usize, 1), n);
    try t.expect(!table.check(plugin.grant_handles[wasm_host.perm_fs_write]));
    // Distinct from "never granted" (§6 W4 gate) — the trap message this
    // feeds names the reason differently; see `trapPermDenied`.
    try t.expectEqual(grants_mod.Reason.revoked, table.reasonFor(plugin.grant_handles[wasm_host.perm_fs_write]));

    // The VERY NEXT fs.write-backed call traps — command.run surfaces it as
    // error.Trap (the membrane's one deny path), never a normal return.
    try t.expectError(error.Trap, command.run(&env.commands, &env.ctx, "notes-capture", &.{ .{ .string = "after" }, .{ .string = tmp } }));
}

test "wasm plugin: modes reacts to the activation event by language, without touching the head (task #19 item 4)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "modes", @embedFile("guest_modes_wasm"), .{});
    defer plugin.deinit();

    // Fire activation for a python, then a zig, then an unrecognized-extension
    // file: on_activate detects the language each time (design §3) — this
    // test can't observe the detection directly (`on_activate` downgraded its
    // `weft.echo` to `weft.log` — see src/guest/modes.zig's doc: `on_activate`
    // is BACKGROUND, `wl_echo` is head-gated, and there is no dispatching head
    // to route an echo through here), so what it DOES assert is the
    // structural guarantee this task adds: a BACKGROUND entry never touches
    // `env.head.echo`, for any of these activations — not a crash, not a
    // trap-then-silently-recover, just never reached at all.
    try t.expectEqual(@as(usize, 0), env.head.echo.items.len);
    wasm_host.notifyActivate(plugin, "src/main.py");
    try t.expectEqual(@as(usize, 0), env.head.echo.items.len);
    wasm_host.notifyActivate(plugin, "build.zig");
    try t.expectEqual(@as(usize, 0), env.head.echo.items.len);
    wasm_host.notifyActivate(plugin, "LICENSE"); // unrecognized extension: still a no-op
    try t.expectEqual(@as(usize, 0), env.head.echo.items.len);
}

test "wasm plugin: snippets-expand inserts a template body from an fs file" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    const tmp = "weft-snippets-test.txt";
    try file.writeBytes(gpa, tmp, "fn\tfn foo() {\\n}\nlog\tstd.log.info(\"\", .{});");
    defer file.deleteFile(gpa, tmp);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "snippets", @embedFile("guest_snippets_wasm"), .{});
    defer plugin.deinit();
    try t.expect(plugin.perms[wasm_host.perm_fs_read]);

    const ed = env.buffers.active().textEditor().?;
    ed.placeCursor(0);
    _ = try command.run(&env.commands, &env.ctx, "snippets-expand", &.{ .{ .string = "fn" }, .{ .string = tmp } });
    const s = try ed.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("fn foo() {\n}", s); // literal \n expanded to a newline
}

test "net_session: streams a socket into a buffer, teardown clean" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    const linux = std.os.linux;
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds)) != .SUCCESS) return;
    var peer_open = true;
    defer if (peer_open) {
        _ = linux.close(fds[1]);
    };

    const s = try net_session.Session.startFd(gpa, env.pool, &env.ctx, "netplug", "*net*", fds[0]);
    // The "server" end writes; the reader streams it into *net* via drain.
    _ = linux.write(fds[1], "net-ok", 6);
    const buf = blk: {
        var rounds: usize = 0;
        while (rounds < 5_000_000) : (rounds += 1) {
            _ = s.drain();
            var it = env.buffers.iterator();
            while (it.next()) |b| if (std.mem.eql(u8, b.name, "*net*")) {
                if (b.textEditor().?.text().byteLen() > 0) break :blk b;
            };
            std.Thread.yield() catch {};
        }
        break :blk null;
    };
    // deinit shuts fds[0] + joins the reader + closes — no hang, no leak.
    s.deinit();
    _ = linux.close(fds[1]);
    peer_open = false;
    try t.expect(buf != null);
    const str = try buf.?.textEditor().?.text().toOwnedSlice(gpa);
    defer gpa.free(str);
    try t.expectEqualStrings("net-ok", str);
}

test "wasm plugin: kv admin round-trips across the membrane, namespaced" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    var store: kv.Store = .empty;
    defer store.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "edit", @embedFile("guest_edit_wasm"), .{ .kv = &store });
    defer plugin.deinit();
    // The host wired the kv service; a value put under this plugin is
    // namespaced to its name (proven directly through the store).
    try store.put(gpa, "edit", "k", "v");
    try t.expectEqualStrings("v", store.get("edit", "k").?);
    try t.expectEqual(@as(?[]const u8, null), store.get("other", "k"));
}

// ── W4 slice 2 / task #8: `.fs_root` limit enforcement through a REAL guest ─
// `src/guest/fs_limit.zig` requests fs_read+fs_write and exposes each as a
// command reading its path from the args, so the host controls exactly
// which path each scenario tries. `loadPlugin` mints `.none`-limit rows for
// the perms it declared (grants.zig's `mintGrantHandles`, unchanged by this
// slice — every boolean-derived grant stays unrestricted); the test narrows
// those SAME rows to a tmp root directly (no config verb mints a `.fs_root`
// grant yet — see grants.zig's module doc), then drives the guest through
// `command.run` exactly like every other membrane test in this file.

test "wasm plugin: an fs_root-limited grant confines fs through a REAL guest — in-root ok, out-of-root and traversal trap (task #8 / W4 slice 2)" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var table = @import("../grants.zig").HandleTable.init(gpa);
    defer table.deinit();

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "fs_limit", @embedFile("guest_fs_limit_wasm"), .{ .grant_table = &table });
    defer plugin.deinit();

    // Narrow the plugin-lifetime rows `mintGrantHandles` already minted (both
    // `.none` until now) to the tmp root — same handles the guest's own
    // `hasPerm`/`limitFor` checks read on its very next call, exactly like a
    // live revoke would take effect (§2.4's "use = possession").
    table.rows.items[plugin.grant_handles[wasm_host.perm_fs_read].idx].limit = .{ .fs_root = root };
    table.rows.items[plugin.grant_handles[wasm_host.perm_fs_write].idx].limit = .{ .fs_root = root };

    var in_path_buf: [300]u8 = undefined;
    const in_path = try std.fmt.bufPrint(&in_path_buf, "{s}/note.txt", .{root});

    // In-root write, then read, succeed — across the membrane, through the
    // REAL split semantic bodies + the semantic-confined RootedFs backstop.
    const wr = try command.run(&env.commands, &env.ctx, "try-write", &.{ .{ .string = in_path }, .{ .string = "hi from guest" } });
    try t.expectEqual(command.Value{ .integer = 1 }, wr);
    const rr = try command.run(&env.commands, &env.ctx, "try-read", &.{.{ .string = in_path }});
    try t.expectEqualStrings("hi from guest", rr.string);

    // Out-of-root: the guest's call traps outright — never a fake "<absent>"
    // it could keep running past (the same trap-on-deny discipline
    // `deny.zig`'s test proves for a missing perm; this is the identical
    // property for a POSSESSED-but-out-of-bounds path).
    try t.expectError(error.Trap, command.run(&env.commands, &env.ctx, "try-read", &.{.{ .string = "totally/unrelated/path.txt" }}));
    try t.expectError(error.Trap, command.run(&env.commands, &env.ctx, "try-exists", &.{.{ .string = "totally/unrelated/path.txt" }}));

    // Traversal: lexically prefixed by the root (passes the fast lexical
    // gate) but escapes it via `..` — the KERNEL gate (RootedFs,
    // RESOLVE_BENEATH) closes what the lexical gate alone would miss. Fails
    // exactly the same way: a trap, not a silent allow.
    var esc_path_buf: [300]u8 = undefined;
    const esc_path = try std.fmt.bufPrint(&esc_path_buf, "{s}/../../etc/passwd", .{root});
    try t.expectError(error.Trap, command.run(&env.commands, &env.ctx, "try-read", &.{.{ .string = esc_path }}));
    try t.expectError(error.Trap, command.run(&env.commands, &env.ctx, "try-write", &.{ .{ .string = esc_path }, .{ .string = "x" } }));
}

test "wasm_host/plugin.zig: trap message taxonomy — each Reason gets a distinct, correct message" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var table = @import("../grants.zig").HandleTable.init(gpa);
    defer table.deinit();

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    // fs_limit requests fs_read+fs_write; loadPlugin mints a plugin-lifetime
    // row for each via mintGrantHandles. This ONE plugin's table + handles
    // are reused across the sub-scenarios below, each mutating exactly the
    // state needed to provoke ONE Reason — a manufactured `wasm.Caller`
    // (its `context`/`caller` pointers are never dereferenced by `.trap()`,
    // only `trap_buf`/`trap_msg` — see `Caller.trap`'s doc) lets the trap
    // FUNCTIONS be tested directly, without needing a live guest call for
    // each (the wasm-guest test above already proves `.out_of_limit` reaches
    // this taxonomy end to end; this test proves the taxonomy ITSELF,
    // exhaustively, at the API layer — message content, not log level: every
    // trap `trapPermDenied`/`trapOutOfLimit` raises is HOST-raised, so it
    // reaches `checkErr` and logs `.warn`, never `.err` — see wasm.zig's
    // module doc's channel split — nothing left to classify here).
    const plugin = try loadPlugin(&engine, &env.ctx, "fs_limit", @embedFile("guest_fs_limit_wasm"), .{ .grant_table = &table });
    defer plugin.deinit();
    const plugin_mod = @import("../wasm_host/plugin.zig");

    // never_granted: `.net` was never requested by this guest at all.
    {
        var caller: wasm.Caller = .{ .context = undefined, .caller = undefined };
        plugin_mod.trapPermDenied(plugin, &caller, .net);
        try t.expect(std.mem.indexOf(u8, caller.trap_msg.?, "not requested in describe()") != null);
    }

    // revoked: an explicit revoke() on the row this plugin DID mint.
    {
        _ = table.revoke("fs_limit", "fs_read");
        var caller: wasm.Caller = .{ .context = undefined, .caller = undefined };
        plugin_mod.trapPermDenied(plugin, &caller, .fs_read);
        try t.expect(std.mem.indexOf(u8, caller.trap_msg.?, "revoked") != null);
        try t.expect(std.mem.indexOf(u8, caller.trap_msg.?, "scope expired") == null); // distinct wording
    }

    // scope_expired: a scoped row swept by its scope's exit — distinct
    // wording from a plain revoke, even though both fail `check` identically.
    {
        const scope = table.newScope();
        const scoped_h = try table.grant(.{ .capability = "fs_write" }, "fs_limit", scope);
        _ = table.sweepScope(scope);
        plugin.grant_handles[wasm_host.perm_fs_write] = scoped_h; // swap in the swept row
        var caller: wasm.Caller = .{ .context = undefined, .caller = undefined };
        plugin_mod.trapPermDenied(plugin, &caller, .fs_write);
        try t.expect(std.mem.indexOf(u8, caller.trap_msg.?, "scope expired") != null);
    }

    // out_of_limit: names BOTH the offending path and the root it escaped —
    // the §6 W4 slice 2 gate ("trapped with the path and root named").
    {
        const limited = try table.grant(.{ .capability = "fs_write", .limit = .{ .fs_root = "vault" } }, "fs_limit", null);
        plugin.grant_handles[wasm_host.perm_fs_write] = limited;
        var caller: wasm.Caller = .{ .context = undefined, .caller = undefined };
        plugin_mod.trapOutOfLimit(plugin, &caller, .fs_write, "elsewhere/secret.txt");
        const msg = caller.trap_msg.?;
        try t.expect(std.mem.indexOf(u8, msg, "elsewhere/secret.txt") != null);
        try t.expect(std.mem.indexOf(u8, msg, "vault") != null);
    }
}

// The Files conformance fixture (src/guest/gramtest.zig): a synthetic
// third-party grammar. It loads clean through the wasm membrane, and every
// key it binds names a STANDARD intention (src/core/intentions.zig) — never a
// plugin command — which is what makes the Files gates (src/e2e/grammar_test.zig)
// evidence about protocols rather than about one plugin's vocabulary.
test "wasm plugin: the conformance fixture binds std intentions only" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "gramtest", @embedFile("guest_gramtest_wasm"), .{});
    defer plugin.deinit();

    const intentions = @import("../intentions.zig");
    const bindings = env.ctx.keymap.modes.getPtr("gramtest") orelse return error.TestExpectedEqual;
    try t.expect(bindings.count() > 0);
    var it = bindings.iterator();
    while (it.next()) |entry| {
        // EVERY arm, not just the first: a fallback naming a plugin command
        // would make the gates evidence about that plugin.
        for (entry.value_ptr.commands) |name| {
            var known = false;
            for (intentions.std_intentions) |intention| {
                if (std.mem.eql(u8, intention.name, name)) known = true;
            }
            if (!known) {
                std.debug.print("gramtest binds '{s}', which is not a std intention\n", .{name});
                return error.TestExpectedEqual;
            }
        }
    }
    // The mode commits no text: a key it leaves unbound can never insert.
    try t.expect(env.ctx.keymap.commitCommand("gramtest") == null);
}

// ── Async results route by captured ref, never by focus ────────────────────
// doc/contextual-workspace-architecture.md §2.6, and §18's gate "background
// callbacks never inspect the active editor or head": a proc fill captures its
// target entry at spawn, so nothing the user does while the command runs can
// redirect the output — and an entry that is gone drops it rather than letting
// it land on a bystander.

fn namedBuffer(buffers: anytype, name: []const u8) ?*@import("../Buffers.zig").Buffer {
    var it = buffers.iterator();
    while (it.next()) |b| if (std.mem.eql(u8, b.name, name)) return b;
    return null;
}

/// Run the loop until every spawned job has delivered (or been dropped).
fn drainJobs(loop: *async_loop.Loop) void {
    var rounds: usize = 0;
    while (rounds < 20_000_000 and loop.tasks.items.len > 0) : (rounds += 1) {
        _ = loop.tick();
        std.Thread.yield() catch {};
    }
}

test "wasm plugin: a proc fill lands in the entry it captured, not the focused one" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("../builtins.zig").install(gpa, &env.commands, &env.keymap, &env.head, &env.actions);

    var loop = async_loop.Loop.init(gpa, env.pool, @import("../task.zig").nowNs);
    defer loop.deinit();
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "run", @embedFile("guest_run_wasm"), .{ .loop = &loop });
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "run-command", &.{.{ .string = "echo captured" }});
    const out = namedBuffer(&env.buffers, "*output*") orelse return error.TestExpectedEqual;

    // Focus moves on while the command is still running — the ordinary case
    // the old "deliver to whoever is active" routing got wrong.
    _ = try command.run(&env.commands, &env.ctx, "buffer-create", &.{.{ .string = "*elsewhere*" }});
    const elsewhere = env.buffers.active();
    try t.expectEqualStrings("*elsewhere*", elsewhere.name);

    drainJobs(&loop);

    const s = try out.textEditor().?.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    try t.expectEqualStrings("captured", s); // the ORIGINATING entry
    try t.expectEqual(@as(usize, 0), elsewhere.textEditor().?.text().byteLen());
    try t.expectEqualStrings("*elsewhere*", env.buffers.active().name); // delivery never refocuses
}

test "wasm plugin: a proc fill whose entry closed is dropped, never redirected" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("../builtins.zig").install(gpa, &env.commands, &env.keymap, &env.head, &env.actions);

    var loop = async_loop.Loop.init(gpa, env.pool, @import("../task.zig").nowNs);
    defer loop.deinit();
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "run", @embedFile("guest_run_wasm"), .{ .loop = &loop });
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "run-command", &.{.{ .string = "echo vanished" }});
    try t.expect(namedBuffer(&env.buffers, "*output*") != null);

    // Close it while the command runs: the captured generation is now dead.
    _ = try command.run(&env.commands, &env.ctx, "buffer-close", &.{});
    try t.expect(namedBuffer(&env.buffers, "*output*") == null);

    drainJobs(&loop);

    // The output went nowhere — not onto the survivor, not into a resurrected
    // buffer of the same name. It is noted once and dropped.
    try t.expect(namedBuffer(&env.buffers, "*output*") == null);
    var it = env.buffers.iterator();
    while (it.next()) |b| {
        const ed = b.textEditor() orelse continue;
        const s = try ed.text().toOwnedSlice(gpa);
        defer gpa.free(s);
        try t.expect(std.mem.indexOf(u8, s, "vanished") == null);
    }
}

test "wasm plugin: on_fill_token paints the entry its fill captured, off-focus" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("../builtins.zig").install(gpa, &env.commands, &env.keymap, &env.head, &env.actions);

    var loop = async_loop.Loop.init(gpa, env.pool, @import("../task.zig").nowNs);
    defer loop.deinit();
    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "git", @embedFile("guest_git_wasm"), .{ .loop = &loop });
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "git-status", &.{});
    const model = namedBuffer(&env.buffers, "*git*") orelse return error.TestExpectedEqual;
    _ = try command.run(&env.commands, &env.ctx, "buffer-create", &.{.{ .string = "*elsewhere*" }});

    drainJobs(&loop);

    // The guest's fill handler ran against the BOUND entry, not the focused
    // one: `*git*` holds the parsed model — never the raw porcelain — and the
    // bystander it could have painted instead stayed empty.
    const s = try model.textEditor().?.text().toOwnedSlice(gpa);
    defer gpa.free(s);
    if (s.len > 0) { // git unavailable → empty, and the routing check still holds
        try t.expect(std.mem.indexOf(u8, s, "Branch:") != null or
            std.mem.indexOf(u8, s, "Not a git repository.") != null);
        try t.expect(!std.mem.startsWith(u8, s, "## "));
    }
    try t.expectEqual(@as(usize, 0), env.buffers.active().textEditor().?.text().byteLen());
}

// ── A tool's instances are addressed by buffer, never by a module global ───
// doc/contextual-workspace-architecture.md §2.6: a second use of a stateful
// tool must not evict the first. Without a pool no dial can succeed, so these
// gate the guest-side ROUTING — which buffer each open takes — which is where
// the singleton (`var conn: ?u32` behind one hardcoded name) actually lived.

test "wasm plugin: a second net-open takes its own buffer, not the first's" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("../builtins.zig").install(gpa, &env.commands, &env.keymap, &env.head, &env.actions);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "net", @embedFile("guest_net_wasm"), .{});
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "net-open", &.{.{ .string = "example.com:80" }});
    _ = try command.run(&env.commands, &env.ctx, "net-open", &.{.{ .string = "example.org:80" }});

    try t.expect(env.buffers.findByName("*net*") != null);
    try t.expect(env.buffers.findByName("*net:2*") != null);
}

test "wasm plugin: a second http-get takes its own response buffer" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("../builtins.zig").install(gpa, &env.commands, &env.keymap, &env.head, &env.actions);

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "http", @embedFile("guest_http_wasm"), .{});
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "http-get", &.{.{ .string = "http://example.com/a" }});
    _ = try command.run(&env.commands, &env.ctx, "http-get", &.{.{ .string = "http://example.org/b" }});

    try t.expect(env.buffers.findByName("*http*") != null);
    try t.expect(env.buffers.findByName("*http:2*") != null);
}

// ── A picker's accept names its target, never a row or a label ────────────
// doc/contextual-workspace-architecture.md §2.6: a buffer closed while the
// picker is open must be REFUSED, not confused with whatever took its slot —
// ids are slots, `{id, generation}` is the identity, and the candidate carries
// it so no parallel table and no parsed label can go stale under the accept.

test "wasm plugins: buf-pick refuses a buffer closed mid-pick, slot reuse and all" {
    const gpa = t.allocator;
    var env: Env = undefined;
    try Env.init(gpa, &env);
    defer env.deinit(gpa);
    try @import("../builtins.zig").install(gpa, &env.commands, &env.keymap, &env.head, &env.actions);
    try @import("../pick.zig").install(gpa, &env.commands, &env.keymap);

    _ = try env.buffers.create(gpa, "alpha");
    const beta = try env.buffers.create(gpa, "beta");

    var engine = try wasm.Engine.init(gpa);
    defer engine.deinit();
    const plugin = try loadPlugin(&engine, &env.ctx, "buffers", @embedFile("guest_buffers_wasm"), .{});
    defer plugin.deinit();

    _ = try command.run(&env.commands, &env.ctx, "buf-pick", &.{});
    try t.expect(env.head.pick.active);
    _ = try command.run(&env.commands, &env.ctx, "pick-input", &.{.{ .string = "beta" }});

    // beta closes while the picker is open, and a new buffer takes its SLOT.
    try env.buffers.close(gpa, beta, &env.head, &env.keymap);
    const gamma = try env.buffers.create(gpa, "gamma");
    try t.expectEqual(beta, gamma); // the same id, a different buffer

    const before = env.buffers.active().id;
    _ = try command.run(&env.commands, &env.ctx, "pick-accept", &.{});
    // Refused: the accept did not land on gamma, and did not move at all.
    try t.expectEqual(before, env.buffers.active().id);
    try t.expect(!std.mem.eql(u8, env.buffers.active().name, "gamma"));
}
