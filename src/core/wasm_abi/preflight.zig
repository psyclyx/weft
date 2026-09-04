const std = @import("std");
const wasm = @import("../wasm.zig");
const t = std.testing;

pub const ContractRow = struct {
    name: []const u8,
    ty: wasm.ExternType,
};

pub const ContractSpec = struct {
    major: []const u8,
    namespace: []const u8,
    export_prefix: []const u8,
    imports: []const ContractRow,
    callbacks: []const ContractRow,
    legacy_callbacks: []const []const u8,
};

pub const ContractError = error{
    InvalidMajor,
    InvalidNamespace,
    InvalidExportPrefix,
    InvalidLogicalName,
    DuplicateImport,
    DuplicateCallback,
    DuplicateLegacyCallback,
    MissingInit,
    UnknownLegacyCallback,
    MiniAbiRun,
};

pub const Contract = struct {
    major: []const u8,
    namespace: []const u8,
    export_prefix: []const u8,
    imports: []const ContractRow,
    callbacks: []const ContractRow,
    legacy_callbacks: []const []const u8,

    pub fn init(spec: ContractSpec) ContractError!Contract {
        if (!canonicalMajor(spec.major)) return error.InvalidMajor;
        if (!namespaceMatches(spec.namespace, spec.major)) return error.InvalidNamespace;
        if (spec.export_prefix.len != spec.namespace.len + 1 or
            !std.mem.startsWith(u8, spec.export_prefix, spec.namespace) or
            spec.export_prefix[spec.export_prefix.len - 1] != '/')
            return error.InvalidExportPrefix;

        for (spec.imports, 0..) |row, i| {
            if (!logicalName(row.name)) return error.InvalidLogicalName;
            for (spec.imports[0..i]) |prior|
                if (std.mem.eql(u8, row.name, prior.name)) return error.DuplicateImport;
        }

        var init_count: usize = 0;
        for (spec.callbacks, 0..) |row, i| {
            if (!logicalName(row.name)) return error.InvalidLogicalName;
            if (std.mem.eql(u8, row.name, "run")) return error.MiniAbiRun;
            if (std.mem.eql(u8, row.name, "init")) init_count += 1;
            for (spec.callbacks[0..i]) |prior|
                if (std.mem.eql(u8, row.name, prior.name)) return error.DuplicateCallback;
        }
        if (init_count == 0) return error.MissingInit;

        for (spec.legacy_callbacks, 0..) |name, i| {
            if (!logicalName(name)) return error.InvalidLogicalName;
            if (std.mem.eql(u8, name, "run")) return error.MiniAbiRun;
            for (spec.legacy_callbacks[0..i]) |prior|
                if (std.mem.eql(u8, name, prior)) return error.DuplicateLegacyCallback;
            var found = false;
            for (spec.callbacks) |row| {
                if (std.mem.eql(u8, name, row.name)) {
                    found = true;
                    break;
                }
            }
            if (!found) return error.UnknownLegacyCallback;
        }

        return .{
            .major = spec.major,
            .namespace = spec.namespace,
            .export_prefix = spec.export_prefix,
            .imports = spec.imports,
            .callbacks = spec.callbacks,
            .legacy_callbacks = spec.legacy_callbacks,
        };
    }
};

fn canonicalMajor(major: []const u8) bool {
    if (major.len == 0 or major[0] < '1' or major[0] > '9') return false;
    for (major[1..]) |ch| if (ch < '0' or ch > '9') return false;
    return true;
}

fn namespaceMatches(namespace: []const u8, major: []const u8) bool {
    const prefix = "weft:abi/";
    return namespace.len == prefix.len + major.len and
        std.mem.startsWith(u8, namespace, prefix) and
        std.mem.eql(u8, namespace[prefix.len..], major);
}

fn logicalName(name: []const u8) bool {
    if (name.len == 0 or name[0] < 'a' or name[0] > 'z') return false;
    for (name[1..]) |ch| {
        if ((ch < 'a' or ch > 'z') and (ch < '0' or ch > '9') and ch != '_')
            return false;
    }
    return true;
}

pub const Direction = enum { guest_import, host_callback };

pub const Refusal = union(enum) {
    legacy_import_namespace: struct { field: []const u8 },
    legacy_callback_export: struct { name: []const u8 },
    malformed_reserved_name: struct { name: []const u8, direction: Direction },
    unsupported_abi_namespace: struct { found: []const u8, supported: []const u8 },
    foreign_import_namespace: struct { module: []const u8, field: []const u8 },
    unknown_import: struct { field: []const u8 },
    unknown_callback: struct { name: []const u8 },
    import_type_mismatch: struct {
        field: []const u8,
        expected: wasm.ExternType,
        found: wasm.ExternType,
    },
    callback_type_mismatch: struct {
        name: []const u8,
        expected: wasm.ExternType,
        found: wasm.ExternType,
    },
    missing_init,
};

const reserved_prefix = "weft:abi/";

const ParsedExport = struct {
    namespace: []const u8,
    major: []const u8,
    callback: []const u8,
};

fn parseImportMajor(namespace: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, namespace, reserved_prefix)) return null;
    const major = namespace[reserved_prefix.len..];
    if (!canonicalMajor(major)) return null;
    return major;
}

fn parseCallback(name: []const u8) ?ParsedExport {
    if (!std.mem.startsWith(u8, name, reserved_prefix)) return null;
    const rest = name[reserved_prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const major = rest[0..slash];
    const callback = rest[slash + 1 ..];
    if (!canonicalMajor(major) or callback.len == 0 or
        std.mem.indexOfScalar(u8, callback, '/') != null)
        return null;
    return .{
        .namespace = name[0 .. reserved_prefix.len + major.len],
        .major = major,
        .callback = callback,
    };
}

fn sameType(a: wasm.ExternType, b: wasm.ExternType) bool {
    return a.kind == b.kind and
        std.mem.eql(wasm.ValKind, a.params, b.params) and
        std.mem.eql(wasm.ValKind, a.results, b.results);
}

fn contractRow(rows: []const ContractRow, name: []const u8) ?ContractRow {
    for (rows) |row| if (std.mem.eql(u8, row.name, name)) return row;
    return null;
}

fn isLegacyCallback(contract: *const Contract, name: []const u8) bool {
    for (contract.legacy_callbacks) |legacy|
        if (std.mem.eql(u8, legacy, name)) return true;
    return false;
}

pub fn validate(interface: *const wasm.OwnedInterface, contract: *const Contract) ?Refusal {
    for (interface.imports) |entry| {
        if (std.mem.eql(u8, entry.module, "weft"))
            return .{ .legacy_import_namespace = .{ .field = entry.name } };
        if (!std.mem.startsWith(u8, entry.module, reserved_prefix))
            return .{ .foreign_import_namespace = .{ .module = entry.module, .field = entry.name } };
        const major = parseImportMajor(entry.module) orelse
            return .{ .malformed_reserved_name = .{ .name = entry.module, .direction = .guest_import } };
        if (!std.mem.eql(u8, major, contract.major))
            return .{ .unsupported_abi_namespace = .{ .found = entry.module, .supported = contract.namespace } };
        const expected = contractRow(contract.imports, entry.name) orelse
            return .{ .unknown_import = .{ .field = entry.name } };
        if (!sameType(expected.ty, entry.ty))
            return .{ .import_type_mismatch = .{
                .field = entry.name,
                .expected = expected.ty,
                .found = entry.ty,
            } };
    }

    var saw_init = false;
    for (interface.exports) |entry| {
        if (std.mem.startsWith(u8, entry.name, reserved_prefix)) {
            const parsed = parseCallback(entry.name) orelse
                return .{ .malformed_reserved_name = .{ .name = entry.name, .direction = .host_callback } };
            if (!std.mem.eql(u8, parsed.major, contract.major))
                return .{ .unsupported_abi_namespace = .{
                    .found = parsed.namespace,
                    .supported = contract.namespace,
                } };
            const expected = contractRow(contract.callbacks, parsed.callback) orelse
                return .{ .unknown_callback = .{ .name = parsed.callback } };
            if (!sameType(expected.ty, entry.ty))
                return .{ .callback_type_mismatch = .{
                    .name = parsed.callback,
                    .expected = expected.ty,
                    .found = entry.ty,
                } };
            if (std.mem.eql(u8, parsed.callback, "init")) saw_init = true;
            continue;
        }
        if (isLegacyCallback(contract, entry.name))
            return .{ .legacy_callback_export = .{ .name = entry.name } };
    }
    if (!saw_init) return .missing_init;
    return null;
}

const void_fn: wasm.ExternType = .{ .kind = .function };
const i32_fn: wasm.ExternType = .{ .kind = .function, .params = &.{.i32} };
const i32_result_fn: wasm.ExternType = .{ .kind = .function, .results = &.{.i32} };
const valid_imports = [_]ContractRow{
    .{ .name = "wl_log", .ty = i32_fn },
    .{ .name = "wl_result", .ty = i32_result_fn },
    .{ .name = "run", .ty = void_fn },
};
const valid_callbacks = [_]ContractRow{
    .{ .name = "init", .ty = void_fn },
    .{ .name = "describe", .ty = void_fn },
    .{ .name = "on_command", .ty = i32_fn },
    .{ .name = "on_result", .ty = i32_result_fn },
};
const valid_legacy = [_][]const u8{ "init", "describe", "on_command" };

fn validSpec() ContractSpec {
    return .{
        .major = "1",
        .namespace = "weft:abi/1",
        .export_prefix = "weft:abi/1/",
        .imports = &valid_imports,
        .callbacks = &valid_callbacks,
        .legacy_callbacks = &valid_legacy,
    };
}

test "preflight contract accepts its canonical consistent shape" {
    _ = try Contract.init(validSpec());
}

test "preflight contract rejects identity disagreement" {
    var spec = validSpec();
    spec.major = "01";
    try t.expectError(error.InvalidMajor, Contract.init(spec));
    spec = validSpec();
    spec.namespace = "weft:abi/2";
    try t.expectError(error.InvalidNamespace, Contract.init(spec));
    spec = validSpec();
    spec.export_prefix = "weft:abi/1x/";
    try t.expectError(error.InvalidExportPrefix, Contract.init(spec));
}

test "preflight contract rejects invalid and duplicate logical names" {
    var imports = valid_imports;
    imports[1].name = "Bad-name";
    var spec = validSpec();
    spec.imports = &imports;
    try t.expectError(error.InvalidLogicalName, Contract.init(spec));

    imports = valid_imports;
    imports[1].name = "wl_log";
    spec = validSpec();
    spec.imports = &imports;
    try t.expectError(error.DuplicateImport, Contract.init(spec));

    var callbacks = valid_callbacks;
    callbacks[2].name = "describe";
    spec = validSpec();
    spec.callbacks = &callbacks;
    try t.expectError(error.DuplicateCallback, Contract.init(spec));

    var legacy = valid_legacy;
    legacy[2] = "describe";
    spec = validSpec();
    spec.legacy_callbacks = &legacy;
    try t.expectError(error.DuplicateLegacyCallback, Contract.init(spec));
}

test "preflight contract pins init, legacy subset, and mini-ABI exclusion" {
    var callbacks = valid_callbacks;
    callbacks[0].name = "start";
    var spec = validSpec();
    spec.callbacks = &callbacks;
    try t.expectError(error.MissingInit, Contract.init(spec));

    callbacks = valid_callbacks;
    callbacks[1].name = "init";
    spec = validSpec();
    spec.callbacks = &callbacks;
    try t.expectError(error.DuplicateCallback, Contract.init(spec));

    var legacy = valid_legacy;
    legacy[2] = "not_a_callback";
    spec = validSpec();
    spec.legacy_callbacks = &legacy;
    try t.expectError(error.UnknownLegacyCallback, Contract.init(spec));

    callbacks = valid_callbacks;
    callbacks[2].name = "run";
    spec = validSpec();
    spec.callbacks = &callbacks;
    try t.expectError(error.MiniAbiRun, Contract.init(spec));

    legacy = valid_legacy;
    legacy[2] = "run";
    spec = validSpec();
    spec.legacy_callbacks = &legacy;
    try t.expectError(error.MiniAbiRun, Contract.init(spec));
}

fn ownedInterface(
    imports: []const wasm.ModuleImport,
    exports: []const wasm.ModuleExport,
) !wasm.OwnedInterface {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    const copied_imports = try allocator.dupe(wasm.ModuleImport, imports);
    const copied_exports = try allocator.dupe(wasm.ModuleExport, exports);
    for (copied_imports) |*row| {
        row.module = try allocator.dupe(u8, row.module);
        row.name = try allocator.dupe(u8, row.name);
        row.ty.params = try allocator.dupe(wasm.ValKind, row.ty.params);
        row.ty.results = try allocator.dupe(wasm.ValKind, row.ty.results);
    }
    for (copied_exports) |*row| {
        row.name = try allocator.dupe(u8, row.name);
        row.ty.params = try allocator.dupe(wasm.ValKind, row.ty.params);
        row.ty.results = try allocator.dupe(wasm.ValKind, row.ty.results);
    }
    return .{ .arena = arena, .imports = copied_imports, .exports = copied_exports };
}

fn refusalTag(interface: *const wasm.OwnedInterface, contract: *const Contract) ?std.meta.Tag(Refusal) {
    const refusal = validate(interface, contract) orelse return null;
    return std.meta.activeTag(refusal);
}

test "preflight accepts supported subsets and optional callback absence" {
    const contract = try Contract.init(validSpec());
    const cases = [_]struct {
        imports: []const wasm.ModuleImport,
        exports: []const wasm.ModuleExport,
    }{
        .{ .imports = &.{}, .exports = &.{.{ .name = "weft:abi/1/init", .ty = void_fn }} },
        .{
            .imports = &.{.{ .module = "weft:abi/1", .name = "wl_log", .ty = i32_fn }},
            .exports = &.{.{ .name = "weft:abi/1/init", .ty = void_fn }},
        },
        .{
            .imports = &.{},
            .exports = &.{
                .{ .name = "memory", .ty = .{ .kind = .memory } },
                .{ .name = "weft:abi/1/init", .ty = void_fn },
                .{ .name = "weft:abi/1/describe", .ty = void_fn },
            },
        },
        .{
            .imports = &.{
                .{ .module = "weft:abi/1", .name = "wl_log", .ty = i32_fn },
                .{ .module = "weft:abi/1", .name = "wl_result", .ty = i32_result_fn },
                .{ .module = "weft:abi/1", .name = "run", .ty = void_fn },
            },
            .exports = &.{
                .{ .name = "weft:abi/1/init", .ty = void_fn },
                .{ .name = "weft:abi/1/describe", .ty = void_fn },
                .{ .name = "weft:abi/1/on_command", .ty = i32_fn },
                .{ .name = "weft:abi/1/on_result", .ty = i32_result_fn },
            },
        },
    };
    for (cases) |case| {
        var interface = try ownedInterface(case.imports, case.exports);
        defer interface.deinit();
        try t.expect(validate(&interface, &contract) == null);
    }
}

test "preflight refusal matrix" {
    const contract = try Contract.init(validSpec());
    const Case = struct {
        imports: []const wasm.ModuleImport = &.{},
        exports: []const wasm.ModuleExport,
        want: std.meta.Tag(Refusal),
    };
    const cases = [_]Case{
        .{ .imports = &.{.{ .module = "weft", .name = "wl_log", .ty = i32_fn }}, .exports = &.{.{ .name = "weft:abi/1/init", .ty = void_fn }}, .want = .legacy_import_namespace },
        .{ .exports = &.{ .{ .name = "init", .ty = void_fn }, .{ .name = "weft:abi/1/init", .ty = void_fn } }, .want = .legacy_callback_export },
        .{ .imports = &.{.{ .module = "weft:abi/01", .name = "wl_log", .ty = i32_fn }}, .exports = &.{.{ .name = "weft:abi/1/init", .ty = void_fn }}, .want = .malformed_reserved_name },
        .{ .exports = &.{ .{ .name = "weft:abi/1x/init", .ty = void_fn }, .{ .name = "weft:abi/1/init", .ty = void_fn } }, .want = .malformed_reserved_name },
        .{ .imports = &.{.{ .module = "weft:abi/999999999999999999999999999999", .name = "wl_log", .ty = i32_fn }}, .exports = &.{.{ .name = "weft:abi/1/init", .ty = void_fn }}, .want = .unsupported_abi_namespace },
        .{ .exports = &.{ .{ .name = "weft:abi/2/init", .ty = void_fn }, .{ .name = "weft:abi/1/init", .ty = void_fn } }, .want = .unsupported_abi_namespace },
        .{ .imports = &.{.{ .module = "wasi_snapshot_preview1", .name = "fd_write", .ty = i32_fn }}, .exports = &.{.{ .name = "weft:abi/1/init", .ty = void_fn }}, .want = .foreign_import_namespace },
        .{ .imports = &.{.{ .module = "weft:abi/1", .name = "wl_missing", .ty = i32_fn }}, .exports = &.{.{ .name = "weft:abi/1/init", .ty = void_fn }}, .want = .unknown_import },
        .{ .exports = &.{ .{ .name = "weft:abi/1/unknown", .ty = void_fn }, .{ .name = "weft:abi/1/init", .ty = void_fn } }, .want = .unknown_callback },
        .{ .imports = &.{.{ .module = "weft:abi/1", .name = "wl_log", .ty = .{ .kind = .memory } }}, .exports = &.{.{ .name = "weft:abi/1/init", .ty = void_fn }}, .want = .import_type_mismatch },
        .{ .imports = &.{.{ .module = "weft:abi/1", .name = "wl_log", .ty = void_fn }}, .exports = &.{.{ .name = "weft:abi/1/init", .ty = void_fn }}, .want = .import_type_mismatch },
        .{ .imports = &.{.{ .module = "weft:abi/1", .name = "wl_result", .ty = void_fn }}, .exports = &.{.{ .name = "weft:abi/1/init", .ty = void_fn }}, .want = .import_type_mismatch },
        .{ .exports = &.{.{ .name = "weft:abi/1/init", .ty = .{ .kind = .global } }}, .want = .callback_type_mismatch },
        .{ .exports = &.{ .{ .name = "weft:abi/1/on_command", .ty = void_fn }, .{ .name = "weft:abi/1/init", .ty = void_fn } }, .want = .callback_type_mismatch },
        .{ .exports = &.{ .{ .name = "weft:abi/1/on_result", .ty = void_fn }, .{ .name = "weft:abi/1/init", .ty = void_fn } }, .want = .callback_type_mismatch },
        .{ .exports = &.{.{ .name = "memory", .ty = .{ .kind = .memory } }}, .want = .missing_init },
    };

    for (cases) |case| {
        var interface = try ownedInterface(case.imports, case.exports);
        defer interface.deinit();
        try t.expectEqual(case.want, refusalTag(&interface, &contract).?);
    }
}

test "preflight preserves import order and checks imports before exports" {
    const contract = try Contract.init(validSpec());
    var interface = try ownedInterface(
        &.{
            .{ .module = "foreign", .name = "first", .ty = void_fn },
            .{ .module = "weft", .name = "second", .ty = void_fn },
        },
        &.{.{ .name = "init", .ty = void_fn }},
    );
    defer interface.deinit();
    const refusal = validate(&interface, &contract).?;
    try t.expectEqual(std.meta.Tag(Refusal).foreign_import_namespace, std.meta.activeTag(refusal));
    try t.expectEqualStrings("foreign", refusal.foreign_import_namespace.module);
    try t.expectEqualStrings("first", refusal.foreign_import_namespace.field);
}

test "preflight checks exports in module order before missing init" {
    const contract = try Contract.init(validSpec());
    var interface = try ownedInterface(&.{}, &.{
        .{ .name = "weft:abi/1/unknown", .ty = void_fn },
        .{ .name = "init", .ty = void_fn },
    });
    defer interface.deinit();
    try t.expectEqual(
        std.meta.Tag(Refusal).unknown_callback,
        refusalTag(&interface, &contract).?,
    );
}

test "preflight reports every malformed reserved boundary with its direction" {
    const contract = try Contract.init(validSpec());
    for ([_][]const u8{ "weft:abi/", "weft:abi/01", "weft:abi/1/" }) |bad| {
        var interface = try ownedInterface(
            &.{.{ .module = bad, .name = "wl_log", .ty = i32_fn }},
            &.{.{ .name = "weft:abi/1/init", .ty = void_fn }},
        );
        defer interface.deinit();
        const refusal = validate(&interface, &contract).?;
        try t.expectEqual(std.meta.Tag(Refusal).malformed_reserved_name, std.meta.activeTag(refusal));
        try t.expectEqual(Direction.guest_import, refusal.malformed_reserved_name.direction);
        try t.expectEqualStrings(bad, refusal.malformed_reserved_name.name);
    }

    for ([_][]const u8{
        "weft:abi/1",
        "weft:abi//init",
        "weft:abi/01/init",
        "weft:abi/1/",
        "weft:abi/1/a/b",
    }) |bad| {
        var interface = try ownedInterface(&.{}, &.{
            .{ .name = bad, .ty = void_fn },
            .{ .name = "weft:abi/1/init", .ty = void_fn },
        });
        defer interface.deinit();
        const refusal = validate(&interface, &contract).?;
        try t.expectEqual(std.meta.Tag(Refusal).malformed_reserved_name, std.meta.activeTag(refusal));
        try t.expectEqual(Direction.host_callback, refusal.malformed_reserved_name.direction);
        try t.expectEqualStrings(bad, refusal.malformed_reserved_name.name);
    }
}

test "preflight treats a slash-free callback segment as syntax before lookup" {
    const contract = try Contract.init(validSpec());
    var interface = try ownedInterface(&.{}, &.{
        .{ .name = "weft:abi/1/Bad-name", .ty = void_fn },
        .{ .name = "weft:abi/1/init", .ty = void_fn },
    });
    defer interface.deinit();
    const refusal = validate(&interface, &contract).?;
    try t.expectEqual(std.meta.Tag(Refusal).unknown_callback, std.meta.activeTag(refusal));
    try t.expectEqualStrings("Bad-name", refusal.unknown_callback.name);
}

test "preflight callback major refusal reports the namespace, not full export" {
    const contract = try Contract.init(validSpec());
    var interface = try ownedInterface(&.{}, &.{
        .{ .name = "weft:abi/2/init", .ty = void_fn },
        .{ .name = "weft:abi/1/init", .ty = void_fn },
    });
    defer interface.deinit();
    const refusal = validate(&interface, &contract).?;
    try t.expectEqual(std.meta.Tag(Refusal).unsupported_abi_namespace, std.meta.activeTag(refusal));
    try t.expectEqualStrings("weft:abi/2", refusal.unsupported_abi_namespace.found);
    try t.expectEqualStrings("weft:abi/1", refusal.unsupported_abi_namespace.supported);
}

test "preflight type refusal borrows direct expected and found shapes" {
    const contract = try Contract.init(validSpec());
    var interface = try ownedInterface(
        &.{.{ .module = "weft:abi/1", .name = "wl_result", .ty = void_fn }},
        &.{.{ .name = "weft:abi/1/init", .ty = void_fn }},
    );
    defer interface.deinit();
    const refusal = validate(&interface, &contract).?;
    try t.expectEqual(std.meta.Tag(Refusal).import_type_mismatch, std.meta.activeTag(refusal));
    try t.expectEqualSlices(wasm.ValKind, &.{.i32}, refusal.import_type_mismatch.expected.results);
    try t.expectEqual(@as(usize, 0), refusal.import_type_mismatch.found.results.len);
}
