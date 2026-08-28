//! Bounded RPC composition for a remote `weft_fs.service.Provider`.
//!
//! Scheduling is deliberately outside this module. `Exchange` may wait on a
//! worker-owned network transport, replay a recorded exchange, or answer
//! in-process. The filesystem contract remains synchronous and contains no
//! transport, editor, files, or modal-editing policy.

const std = @import("std");
const semantic = @import("weft_semantic");
const fs = @import("weft_fs");
const codec = @import("weft_fs_codec");

const c = fs.contract;
const wire_authority = semantic.handle.Authority.here;
const magic = "WFR";
const version: u8 = 1;
const max_packet_bytes = codec.Limits.max_payload_bytes + 1024;

/// Which export surfaces of the shared root this server answers for, granted
/// one by one (`core/peer_fs.zig`'s `Grant` is the same split at the envelope
/// edge): listing a tree, reading bytes, changing it. Handle plumbing (root
/// derivation, leases, watches) rides whichever surface asked for it — the
/// three gates are on the ops that disclose or change something.
pub const Access = struct {
    hierarchy: bool = false,
    bytes: bool = false,
    mutate: bool = false,

    pub const read: Access = .{ .hierarchy = true, .bytes = true };
    pub const read_write: Access = .{ .hierarchy = true, .bytes = true, .mutate = true };
};

const Op = enum(u8) {
    root,
    capabilities,
    same_root,
    derive_root,
    release_root,
    observe,
    list,
    read,
    capture,
    release_lease,
    apply,
    watch,
    poll_invalidation,
    close_watch,
};

const Status = enum(u8) {
    ok,
    not_found,
    already_exists,
    not_directory,
    permission_denied,
    confined,
    stale,
    cross_device,
    unsupported,
    invalid_name,
    busy,
    io,
    limit_exceeded,
    out_of_memory,
    invalid_request,
};

const Writer = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    fn init(gpa: std.mem.Allocator) Writer {
        return .{ .gpa = gpa };
    }

    fn deinit(self: *Writer) void {
        self.bytes.deinit(self.gpa);
    }

    fn append(self: *Writer, bytes: []const u8) !void {
        if (bytes.len > max_packet_bytes -| self.bytes.items.len) return error.LimitExceeded;
        try self.bytes.appendSlice(self.gpa, bytes);
    }

    fn byte(self: *Writer, value: u8) !void {
        try self.append(&.{value});
    }

    fn boolValue(self: *Writer, value: bool) !void {
        try self.byte(@intFromBool(value));
    }

    fn u32Value(self: *Writer, value: u32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try self.append(&bytes);
    }

    fn u64Value(self: *Writer, value: u64) !void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try self.append(&bytes);
    }

    fn bytesValue(self: *Writer, value: []const u8) !void {
        if (value.len > codec.Limits.max_payload_bytes) return error.LimitExceeded;
        try self.u64Value(@intCast(value.len));
        try self.append(value);
    }

    fn requestHeader(self: *Writer, op: Op) !void {
        try self.append(magic);
        try self.byte(version);
        try self.byte(@intFromEnum(op));
    }

    fn responseHeader(self: *Writer, status: Status) !void {
        try self.append(magic);
        try self.byte(version);
        try self.byte(@intFromEnum(status));
    }

    fn finish(self: *Writer) ![]u8 {
        return self.bytes.toOwnedSlice(self.gpa);
    }
};

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn init(bytes: []const u8) c.Error!Reader {
        if (bytes.len > max_packet_bytes) return error.LimitExceeded;
        return .{ .bytes = bytes };
    }

    fn take(self: *Reader, len: usize) c.Error![]const u8 {
        if (len > self.bytes.len -| self.pos) return error.Io;
        const result = self.bytes[self.pos .. self.pos + len];
        self.pos += len;
        return result;
    }

    fn byte(self: *Reader) c.Error!u8 {
        return (try self.take(1))[0];
    }

    fn boolValue(self: *Reader) c.Error!bool {
        return switch (try self.byte()) {
            0 => false,
            1 => true,
            else => error.Io,
        };
    }

    fn u32Value(self: *Reader) c.Error!u32 {
        var bytes: [4]u8 = undefined;
        @memcpy(&bytes, try self.take(bytes.len));
        return std.mem.readInt(u32, &bytes, .little);
    }

    fn u64Value(self: *Reader) c.Error!u64 {
        var bytes: [8]u8 = undefined;
        @memcpy(&bytes, try self.take(bytes.len));
        return std.mem.readInt(u64, &bytes, .little);
    }

    fn bytesValue(self: *Reader) c.Error![]const u8 {
        const len = try self.u64Value();
        if (len > codec.Limits.max_payload_bytes or len > std.math.maxInt(usize)) return error.LimitExceeded;
        return self.take(@intCast(len));
    }

    fn requestHeader(self: *Reader) c.Error!Op {
        if (!std.mem.eql(u8, try self.take(magic.len), magic)) return error.Io;
        if (try self.byte() != version) return error.Io;
        return std.enums.fromInt(Op, try self.byte()) orelse error.Io;
    }

    fn responseHeader(self: *Reader) c.Error!Status {
        if (!std.mem.eql(u8, try self.take(magic.len), magic)) return error.Io;
        if (try self.byte() != version) return error.Io;
        return std.enums.fromInt(Status, try self.byte()) orelse error.Io;
    }

    fn done(self: *const Reader) c.Error!void {
        if (self.pos != self.bytes.len) return error.Io;
    }
};

pub const Exchange = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        round_trip: *const fn (*anyopaque, std.mem.Allocator, []const u8) c.Error![]u8,
    };

    pub fn init(pointer: anytype) Exchange {
        const Pointer = @TypeOf(pointer);
        const info = switch (@typeInfo(Pointer)) {
            .pointer => |value| value,
            else => @compileError("remote filesystem exchange requires a pointer"),
        };
        if (info.size != .one or info.is_const)
            @compileError("remote filesystem exchange requires a mutable single-item pointer");
        const Implementation = info.child;
        const Adapter = struct {
            fn roundTrip(raw: *anyopaque, gpa: std.mem.Allocator, request: []const u8) c.Error![]u8 {
                const self: *Implementation = @ptrCast(@alignCast(raw));
                return self.roundTrip(gpa, request);
            }
            const vtable: VTable = .{ .round_trip = @This().roundTrip };
        };
        return .{ .context = pointer, .vtable = &Adapter.vtable };
    }

    pub fn roundTrip(self: Exchange, gpa: std.mem.Allocator, request: []const u8) c.Error![]u8 {
        return self.vtable.round_trip(self.context, gpa, request);
    }
};

pub const Provider = struct {
    authority: semantic.handle.Authority,
    exchange: Exchange,

    pub fn init(authority: semantic.handle.Authority, exchange: Exchange) error{InvalidAuthority}!Provider {
        if (authority == wire_authority) return error.InvalidAuthority;
        return .{ .authority = authority, .exchange = exchange };
    }

    pub fn provider(self: *Provider) fs.service.Provider {
        return .init(self);
    }

    pub fn acquireRoot(self: *Provider) c.Error!c.Root {
        var request = try beginRequest(std.heap.page_allocator, .root);
        defer request.deinit();
        var response = try self.call(std.heap.page_allocator, &request);
        defer response.deinit();
        const root = try readHandle(c.Root, &response.reader, wire_authority, self.authority);
        try response.reader.done();
        return root;
    }

    pub fn capabilities(self: *Provider, root: c.Root) c.Error!c.Capabilities {
        var request = try beginRequest(std.heap.page_allocator, .capabilities);
        defer request.deinit();
        try writeHandle(&request, root, self.authority, wire_authority);
        var response = try self.call(std.heap.page_allocator, &request);
        defer response.deinit();
        const payload = try response.reader.bytesValue();
        try response.reader.done();
        return codec.decodeCapabilities(std.heap.page_allocator, payload) catch return error.Io;
    }

    pub fn sameRoot(self: *Provider, left: c.Root, right: c.Root) c.Error!bool {
        var request = try beginRequest(std.heap.page_allocator, .same_root);
        defer request.deinit();
        try writeHandle(&request, left, self.authority, wire_authority);
        try writeHandle(&request, right, self.authority, wire_authority);
        var response = try self.call(std.heap.page_allocator, &request);
        defer response.deinit();
        const result = try response.reader.boolValue();
        try response.reader.done();
        return result;
    }

    pub fn deriveRoot(self: *Provider, source: c.EntrySource) c.Error!c.Root {
        var request = try beginRequest(std.heap.page_allocator, .derive_root);
        defer request.deinit();
        try writeEntrySource(&request, source, self.authority, wire_authority);
        var response = try self.call(std.heap.page_allocator, &request);
        defer response.deinit();
        const root = try readHandle(c.Root, &response.reader, wire_authority, self.authority);
        try response.reader.done();
        return root;
    }

    pub fn releaseRoot(self: *Provider, root: c.Root) void {
        var request = beginRequest(std.heap.page_allocator, .release_root) catch return;
        defer request.deinit();
        writeHandle(&request, root, self.authority, wire_authority) catch return;
        var response = self.call(std.heap.page_allocator, &request) catch return;
        defer response.deinit();
        response.reader.done() catch return;
    }

    pub fn observe(self: *Provider, gpa: std.mem.Allocator, root: c.Root, node: c.NodeRef) c.Error!c.OwnedObservation {
        var request = try beginRequest(gpa, .observe);
        defer request.deinit();
        try writeHandle(&request, root, self.authority, wire_authority);
        try writeNode(&request, node, self.authority, wire_authority);
        var response = try self.call(gpa, &request);
        defer response.deinit();
        const payload = try response.reader.bytesValue();
        try response.reader.done();
        var decoded = codec.decodeObservation(gpa, payload) catch return error.Io;
        errdefer decoded.deinit();
        translateObservation(&decoded.value, wire_authority, self.authority) catch return error.Io;
        var result = c.OwnedObservation.init(gpa);
        errdefer result.deinit();
        result.value = try cloneObservation(result.allocator(), decoded.value);
        decoded.deinit();
        return result;
    }

    pub fn list(self: *Provider, gpa: std.mem.Allocator, root: c.Root, node: c.NodeRef) c.Error!c.OwnedListing {
        var request = try beginRequest(gpa, .list);
        defer request.deinit();
        try writeHandle(&request, root, self.authority, wire_authority);
        try writeNode(&request, node, self.authority, wire_authority);
        var response = try self.call(gpa, &request);
        defer response.deinit();
        const payload = try response.reader.bytesValue();
        try response.reader.done();
        var decoded = codec.decodeListing(gpa, payload) catch return error.Io;
        errdefer decoded.deinit();
        translateListing(&decoded.value, wire_authority, self.authority) catch return error.Io;
        var result = c.OwnedListing.init(gpa);
        errdefer result.deinit();
        result.value = try cloneListing(result.allocator(), decoded.value);
        decoded.deinit();
        return result;
    }

    pub fn read(self: *Provider, gpa: std.mem.Allocator, request_value: c.ReadRequest) c.Error!c.OwnedReadResult {
        var request = try beginRequest(gpa, .read);
        defer request.deinit();
        try writeSource(&request, request_value.source, self.authority, wire_authority);
        try request.u64Value(request_value.offset);
        try request.boolValue(request_value.limit != null);
        if (request_value.limit) |limit| try request.u64Value(limit);
        var response = try self.call(gpa, &request);
        defer response.deinit();
        const payload = try response.reader.bytesValue();
        try response.reader.done();
        var decoded = codec.decodeReadResult(gpa, payload) catch return error.Io;
        errdefer decoded.deinit();
        translateObservation(&decoded.value.observation, wire_authority, self.authority) catch return error.Io;
        var result = c.OwnedReadResult.init(gpa);
        errdefer result.deinit();
        result.value = .{
            .observation = try cloneObservation(result.allocator(), decoded.value.observation),
            .bytes = try result.allocator().dupe(u8, decoded.value.bytes),
            .eof = decoded.value.eof,
        };
        decoded.deinit();
        return result;
    }

    pub fn capture(self: *Provider, source: c.EntrySource) c.Error!c.LeaseRef {
        var request = try beginRequest(std.heap.page_allocator, .capture);
        defer request.deinit();
        try writeEntrySource(&request, source, self.authority, wire_authority);
        var response = try self.call(std.heap.page_allocator, &request);
        defer response.deinit();
        const lease = try readHandle(c.LeaseRef, &response.reader, wire_authority, self.authority);
        try response.reader.done();
        return lease;
    }

    pub fn releaseLease(self: *Provider, source: c.LeaseSource) void {
        var request = beginRequest(std.heap.page_allocator, .release_lease) catch return;
        defer request.deinit();
        writeLeaseSource(&request, source, self.authority, wire_authority) catch return;
        var response = self.call(std.heap.page_allocator, &request) catch return;
        defer response.deinit();
        response.reader.done() catch return;
    }

    pub fn apply(self: *Provider, gpa: std.mem.Allocator, effect_plan: c.Plan) c.Error!c.OwnedApplyReport {
        var canonical = try clonePlan(gpa, effect_plan);
        defer canonical.deinit();
        translatePlan(&canonical.value, self.authority, wire_authority) catch return error.Confined;
        const encoded = codec.encodePlan(gpa, canonical.value) catch return error.LimitExceeded;
        defer gpa.free(encoded);
        var request = try beginRequest(gpa, .apply);
        defer request.deinit();
        try request.bytesValue(encoded);
        var response = try self.call(gpa, &request);
        defer response.deinit();
        const payload = try response.reader.bytesValue();
        try response.reader.done();
        var decoded = codec.decodeApplyReport(gpa, payload) catch return error.Io;
        errdefer decoded.deinit();
        translateReport(&decoded.value, wire_authority, self.authority) catch return error.Io;
        var result = c.OwnedApplyReport.init(gpa);
        errdefer result.deinit();
        result.value = try cloneReport(result.allocator(), decoded.value);
        decoded.deinit();
        return result;
    }

    pub fn watch(self: *Provider, root: c.Root, node: c.NodeRef, recursive: bool) c.Error!c.WatchRef {
        var request = try beginRequest(std.heap.page_allocator, .watch);
        defer request.deinit();
        try writeHandle(&request, root, self.authority, wire_authority);
        try writeNode(&request, node, self.authority, wire_authority);
        try request.boolValue(recursive);
        var response = try self.call(std.heap.page_allocator, &request);
        defer response.deinit();
        const watch_ref = try readHandle(c.WatchRef, &response.reader, wire_authority, self.authority);
        try response.reader.done();
        return watch_ref;
    }

    pub fn pollInvalidation(self: *Provider, watch_ref: c.WatchRef) c.Error!?c.Invalidation {
        var request = try beginRequest(std.heap.page_allocator, .poll_invalidation);
        defer request.deinit();
        try writeHandle(&request, watch_ref, self.authority, wire_authority);
        var response = try self.call(std.heap.page_allocator, &request);
        defer response.deinit();
        const present = try response.reader.boolValue();
        if (!present) {
            try response.reader.done();
            return null;
        }
        const result = try readInvalidation(&response.reader, wire_authority, self.authority);
        try response.reader.done();
        return result;
    }

    pub fn closeWatch(self: *Provider, watch_ref: c.WatchRef) void {
        var request = beginRequest(std.heap.page_allocator, .close_watch) catch return;
        defer request.deinit();
        writeHandle(&request, watch_ref, self.authority, wire_authority) catch return;
        var response = self.call(std.heap.page_allocator, &request) catch return;
        defer response.deinit();
        response.reader.done() catch return;
    }

    const Response = struct {
        bytes: []u8,
        gpa: std.mem.Allocator,
        reader: Reader,

        fn deinit(self: *Response) void {
            self.gpa.free(self.bytes);
            self.* = undefined;
        }
    };

    fn call(self: *Provider, gpa: std.mem.Allocator, request: *Writer) c.Error!Response {
        const bytes = try request.finish();
        request.bytes = .empty;
        defer gpa.free(bytes);
        const response_bytes = try self.exchange.roundTrip(gpa, bytes);
        errdefer gpa.free(response_bytes);
        var reader = Reader.init(response_bytes) catch return error.Io;
        const status = reader.responseHeader() catch return error.Io;
        try statusError(status);
        return .{ .bytes = response_bytes, .gpa = gpa, .reader = reader };
    }
};

pub const Server = struct {
    /// A Server is the lifetime boundary for the wire connection. Handles
    /// minted by this server are not transferable to another Server, even if
    /// both servers wrap the same provider authority. There is no client id
    /// in the wire protocol, so requests made through one Server instance are
    /// intentionally one trust domain; the typed registries below are the
    /// complete ownership membrane at that boundary.
    const RootLease = struct {
        handle: c.Root,
        /// The shared root is borrowed from the server owner. Derived roots
        /// are owned once per successful derive_root result.
        owned: bool,
        count: usize = 1,
    };

    const Lease = struct {
        source: c.LeaseSource,
        count: usize = 1,
    };

    const Watch = struct {
        handle: c.WatchRef,
        count: usize = 1,
    };

    gpa: std.mem.Allocator,
    provider: fs.service.Provider,
    shared_root: c.Root,
    access: Access,
    roots: std.AutoHashMap(u128, RootLease),
    leases: std.AutoHashMap(u128, Lease),
    watches: std.AutoHashMap(u128, Watch),

    pub fn init(gpa: std.mem.Allocator, provider: fs.service.Provider, shared_root: c.Root, access: Access) !Server {
        if (shared_root.generation == 0) return error.InvalidHandle;
        var result: Server = .{
            .gpa = gpa,
            .provider = provider,
            .shared_root = shared_root,
            .access = access,
            .roots = .init(gpa),
            .leases = .init(gpa),
            .watches = .init(gpa),
        };
        errdefer {
            result.roots.deinit();
            result.leases.deinit();
            result.watches.deinit();
        }
        try result.roots.put(handleKey(shared_root), .{ .handle = shared_root, .owned = false });
        var observation = try provider.observe(gpa, shared_root, .root);
        defer observation.deinit();
        if (observation.value.kind != .directory) return error.NotDirectory;
        return result;
    }

    pub fn deinit(self: *Server) void {
        var roots = self.roots.valueIterator();
        while (roots.next()) |record| {
            if (!record.owned) continue;
            var remaining = record.count;
            while (remaining != 0) : (remaining -= 1) self.provider.releaseRoot(record.handle);
        }
        var leases = self.leases.valueIterator();
        while (leases.next()) |record| {
            var remaining = record.count;
            while (remaining != 0) : (remaining -= 1) self.provider.releaseLease(record.source);
        }
        var watches = self.watches.valueIterator();
        while (watches.next()) |record| {
            var remaining = record.count;
            while (remaining != 0) : (remaining -= 1) self.provider.closeWatch(record.handle);
        }
        self.roots.deinit();
        self.leases.deinit();
        self.watches.deinit();
        self.* = undefined;
    }

    pub fn handle(self: *Server, gpa: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error![]u8 {
        return self.dispatch(gpa, bytes) catch |err| reply(gpa, statusOf(err), &.{}) catch return error.OutOfMemory;
    }

    fn dispatch(self: *Server, gpa: std.mem.Allocator, bytes: []const u8) c.Error![]u8 {
        var reader = try Reader.init(bytes);
        const op = try reader.requestHeader();
        return switch (op) {
            .root => blk: {
                try reader.done();
                var payload = Writer.init(gpa);
                defer payload.deinit();
                try writeHandle(&payload, self.shared_root, self.shared_root.authority, wire_authority);
                break :blk try okReply(gpa, &payload);
            },
            .capabilities => blk: {
                const root = try self.readRoot(&reader);
                try reader.done();
                var capabilities = try self.provider.capabilities(root);
                if (!self.access.mutate) capabilities = readOnlyCapabilities(capabilities);
                const encoded = codec.encodeCapabilities(gpa, capabilities) catch return error.LimitExceeded;
                defer gpa.free(encoded);
                break :blk try bytesReply(gpa, encoded);
            },
            .same_root => blk: {
                const left = try self.readRoot(&reader);
                const right = try self.readRoot(&reader);
                try reader.done();
                var payload = Writer.init(gpa);
                defer payload.deinit();
                try payload.boolValue(try self.provider.sameRoot(left, right));
                break :blk try okReply(gpa, &payload);
            },
            .derive_root => blk: {
                const source = try readEntrySource(&reader, wire_authority, self.shared_root.authority);
                try reader.done();
                try self.authorizeRoot(source.root);
                const root = try self.provider.deriveRoot(source);
                var retained = false;
                errdefer if (!retained) self.provider.releaseRoot(root);
                if (root.authority != self.shared_root.authority or root.generation == 0) return error.Io;
                try self.retainRoot(root, true);
                retained = true;
                var committed = false;
                errdefer if (!committed) self.releaseRoot(root) catch {};
                var payload = Writer.init(gpa);
                defer payload.deinit();
                try writeHandle(&payload, root, self.shared_root.authority, wire_authority);
                const result = try okReply(gpa, &payload);
                committed = true;
                break :blk result;
            },
            .release_root => blk: {
                const root = try self.readRoot(&reader);
                try reader.done();
                if (!root.eql(self.shared_root)) {
                    try self.releaseRoot(root);
                }
                break :blk try reply(gpa, .ok, &.{});
            },
            .observe => blk: {
                const root = try self.readRoot(&reader);
                const node = try readNode(&reader, wire_authority, self.shared_root.authority);
                try reader.done();
                var observed = try self.provider.observe(gpa, root, node);
                defer observed.deinit();
                try translateObservation(&observed.value, self.shared_root.authority, wire_authority);
                const encoded = codec.encodeObservation(gpa, observed.value) catch return error.LimitExceeded;
                defer gpa.free(encoded);
                break :blk try bytesReply(gpa, encoded);
            },
            .list => blk: {
                if (!self.access.hierarchy) return error.PermissionDenied;
                const root = try self.readRoot(&reader);
                const node = try readNode(&reader, wire_authority, self.shared_root.authority);
                try reader.done();
                var listing = try self.provider.list(gpa, root, node);
                defer listing.deinit();
                try translateListing(&listing.value, self.shared_root.authority, wire_authority);
                const encoded = codec.encodeListing(gpa, listing.value) catch return error.LimitExceeded;
                defer gpa.free(encoded);
                break :blk try bytesReply(gpa, encoded);
            },
            .read => blk: {
                if (!self.access.bytes) return error.PermissionDenied;
                const source = try readSource(&reader, wire_authority, self.shared_root.authority);
                try self.authorizeSource(source);
                const offset = try reader.u64Value();
                const limit = if (try reader.boolValue()) try reader.u64Value() else null;
                try reader.done();
                var result = try self.provider.read(gpa, .{ .source = source, .offset = offset, .limit = limit });
                defer result.deinit();
                try translateObservation(&result.value.observation, self.shared_root.authority, wire_authority);
                const encoded = codec.encodeReadResult(gpa, result.value) catch return error.LimitExceeded;
                defer gpa.free(encoded);
                break :blk try bytesReply(gpa, encoded);
            },
            .capture => blk: {
                const source = try readEntrySource(&reader, wire_authority, self.shared_root.authority);
                try reader.done();
                try self.authorizeRoot(source.root);
                const lease = try self.provider.capture(source);
                var retained = false;
                errdefer if (!retained) self.provider.releaseLease(.{ .root = source.root, .ref = lease });
                if (lease.authority != self.shared_root.authority or lease.generation == 0) return error.Io;
                try self.retainLease(.{ .root = source.root, .ref = lease });
                retained = true;
                var committed = false;
                errdefer if (!committed) self.releaseLease(.{ .root = source.root, .ref = lease }) catch {};
                var payload = Writer.init(gpa);
                defer payload.deinit();
                try writeHandle(&payload, lease, self.shared_root.authority, wire_authority);
                const result = try okReply(gpa, &payload);
                committed = true;
                break :blk result;
            },
            .release_lease => blk: {
                const source = try readLeaseSource(&reader, wire_authority, self.shared_root.authority);
                try reader.done();
                try self.releaseLease(source);
                break :blk try reply(gpa, .ok, &.{});
            },
            .apply => blk: {
                if (!self.access.mutate) return error.PermissionDenied;
                const encoded_plan = try reader.bytesValue();
                try reader.done();
                var plan = codec.decodePlan(gpa, encoded_plan) catch return error.InvalidName;
                defer plan.deinit();
                try translatePlan(&plan.value, wire_authority, self.shared_root.authority);
                try self.authorizePlan(plan.value);
                var report = self.provider.apply(gpa, plan.value) catch |err| return switch (err) {
                    error.InvalidDependency, error.DuplicateOperationId, error.InvalidApplyReport => error.Io,
                    else => |provider_error| provider_error,
                };
                defer report.deinit();
                try translateReport(&report.value, self.shared_root.authority, wire_authority);
                const encoded = codec.encodeApplyReport(gpa, report.value) catch return error.LimitExceeded;
                defer gpa.free(encoded);
                break :blk try bytesReply(gpa, encoded);
            },
            .watch => blk: {
                const root = try self.readRoot(&reader);
                const node = try readNode(&reader, wire_authority, self.shared_root.authority);
                const recursive = try reader.boolValue();
                try reader.done();
                const watch_ref = try self.provider.watch(root, node, recursive);
                var retained = false;
                errdefer if (!retained) self.provider.closeWatch(watch_ref);
                if (watch_ref.authority != self.shared_root.authority or watch_ref.generation == 0) return error.Io;
                try self.retainWatch(watch_ref);
                retained = true;
                var committed = false;
                errdefer if (!committed) self.releaseWatch(watch_ref) catch {};
                var payload = Writer.init(gpa);
                defer payload.deinit();
                try writeHandle(&payload, watch_ref, self.shared_root.authority, wire_authority);
                const result = try okReply(gpa, &payload);
                committed = true;
                break :blk result;
            },
            .poll_invalidation => blk: {
                const watch_ref = try readHandle(c.WatchRef, &reader, wire_authority, self.shared_root.authority);
                try reader.done();
                try self.authorizeWatch(watch_ref);
                const invalidation = try self.provider.pollInvalidation(watch_ref);
                var payload = Writer.init(gpa);
                defer payload.deinit();
                try payload.boolValue(invalidation != null);
                if (invalidation) |value| try writeInvalidation(&payload, value, self.shared_root.authority, wire_authority);
                break :blk try okReply(gpa, &payload);
            },
            .close_watch => blk: {
                const watch_ref = try readHandle(c.WatchRef, &reader, wire_authority, self.shared_root.authority);
                try reader.done();
                try self.releaseWatch(watch_ref);
                break :blk try reply(gpa, .ok, &.{});
            },
        };
    }

    fn readRoot(self: *Server, reader: *Reader) c.Error!c.Root {
        const root = try readHandle(c.Root, reader, wire_authority, self.shared_root.authority);
        try self.authorizeRoot(root);
        return root;
    }

    fn authorizeRoot(self: *const Server, root: c.Root) c.Error!void {
        if (root.authority != self.shared_root.authority or !self.roots.contains(handleKey(root))) return error.Confined;
    }

    fn authorizeSource(self: *const Server, source: c.Source) c.Error!void {
        switch (source) {
            .entry => |entry| try self.authorizeRoot(entry.root),
            .lease => |lease| try self.authorizeLease(lease),
        }
    }

    fn retainRoot(self: *Server, root: c.Root, owned: bool) c.Error!void {
        const key = handleKey(root);
        if (self.roots.getPtr(key)) |record| {
            if (!record.handle.eql(root) or record.owned != owned) return error.Io;
            try incrementCount(&record.count);
            return;
        }
        try self.roots.put(key, .{ .handle = root, .owned = owned });
    }

    fn releaseRoot(self: *Server, root: c.Root) c.Error!void {
        const key = handleKey(root);
        const record = self.roots.getPtr(key) orelse return error.Confined;
        if (!record.handle.eql(root)) return error.Confined;
        if (!record.owned) return;
        if (record.count > 1) {
            record.count -= 1;
            return;
        }
        const owned_handle = record.handle;
        _ = self.roots.remove(key);
        self.provider.releaseRoot(owned_handle);
    }

    fn retainLease(self: *Server, source: c.LeaseSource) c.Error!void {
        const key = handleKey(source.ref);
        if (self.leases.getPtr(key)) |record| {
            if (!record.source.root.eql(source.root) or !record.source.ref.eql(source.ref)) return error.Io;
            try incrementCount(&record.count);
            return;
        }
        try self.leases.put(key, .{ .source = source });
    }

    fn authorizeLease(self: *const Server, source: c.LeaseSource) c.Error!void {
        const record = self.leases.getPtr(handleKey(source.ref)) orelse return error.Confined;
        if (!record.source.root.eql(source.root) or !record.source.ref.eql(source.ref)) return error.Confined;
    }

    fn releaseLease(self: *Server, source: c.LeaseSource) c.Error!void {
        try self.authorizeLease(source);
        const key = handleKey(source.ref);
        const record = self.leases.getPtr(key).?;
        if (record.count > 1) {
            record.count -= 1;
            return;
        }
        const owned = self.leases.fetchRemove(key).?.value;
        self.provider.releaseLease(owned.source);
    }

    fn retainWatch(self: *Server, watch_ref: c.WatchRef) c.Error!void {
        const key = handleKey(watch_ref);
        if (self.watches.getPtr(key)) |record| {
            if (!record.handle.eql(watch_ref)) return error.Io;
            try incrementCount(&record.count);
            return;
        }
        try self.watches.put(key, .{ .handle = watch_ref });
    }

    fn authorizeWatch(self: *const Server, watch_ref: c.WatchRef) c.Error!void {
        const record = self.watches.getPtr(handleKey(watch_ref)) orelse return error.Confined;
        if (!record.handle.eql(watch_ref)) return error.Confined;
    }

    fn releaseWatch(self: *Server, watch_ref: c.WatchRef) c.Error!void {
        try self.authorizeWatch(watch_ref);
        const key = handleKey(watch_ref);
        const record = self.watches.getPtr(key).?;
        if (record.count > 1) {
            record.count -= 1;
            return;
        }
        const owned = self.watches.fetchRemove(key).?.value;
        self.provider.closeWatch(owned.handle);
    }

    fn authorizePlan(self: *const Server, plan: c.Plan) c.Error!void {
        try self.authorizeRoot(plan.root);
        for (plan.operations) |planned| switch (planned.operation) {
            .copy => |copy| try self.authorizeSource(copy.source),
            .rename => |rename| try self.authorizeRoot(rename.source.root),
            .remove => |remove| try self.authorizeRoot(remove.source.root),
            .set_permissions => |permissions| try self.authorizeRoot(permissions.source.root),
            else => {},
        };
    }
};

fn incrementCount(count: *usize) c.Error!void {
    count.* = std.math.add(usize, count.*, 1) catch return error.LimitExceeded;
}

fn beginRequest(gpa: std.mem.Allocator, op: Op) !Writer {
    var writer = Writer.init(gpa);
    errdefer writer.deinit();
    try writer.requestHeader(op);
    return writer;
}

fn reply(gpa: std.mem.Allocator, status: Status, payload: []const u8) ![]u8 {
    var writer = Writer.init(gpa);
    defer writer.deinit();
    try writer.responseHeader(status);
    try writer.append(payload);
    return writer.finish();
}

fn okReply(gpa: std.mem.Allocator, payload: *Writer) ![]u8 {
    return reply(gpa, .ok, payload.bytes.items);
}

fn bytesReply(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var payload = Writer.init(gpa);
    defer payload.deinit();
    try payload.bytesValue(bytes);
    return okReply(gpa, &payload);
}

fn statusOf(err: anyerror) Status {
    return switch (err) {
        error.NotFound => .not_found,
        error.AlreadyExists => .already_exists,
        error.NotDirectory => .not_directory,
        error.PermissionDenied => .permission_denied,
        error.Confined => .confined,
        error.Stale => .stale,
        error.CrossDevice => .cross_device,
        error.Unsupported => .unsupported,
        error.InvalidName => .invalid_name,
        error.Busy => .busy,
        error.LimitExceeded => .limit_exceeded,
        error.OutOfMemory => .out_of_memory,
        else => .io,
    };
}

fn statusError(status: Status) c.Error!void {
    return switch (status) {
        .ok => {},
        .not_found => error.NotFound,
        .already_exists => error.AlreadyExists,
        .not_directory => error.NotDirectory,
        .permission_denied => error.PermissionDenied,
        .confined => error.Confined,
        .stale => error.Stale,
        .cross_device => error.CrossDevice,
        .unsupported => error.Unsupported,
        .invalid_name => error.InvalidName,
        .busy => error.Busy,
        .io, .invalid_request => error.Io,
        .limit_exceeded => error.LimitExceeded,
        .out_of_memory => error.OutOfMemory,
    };
}

fn writeHandle(writer: *Writer, handle: anytype, from: semantic.handle.Authority, to: semantic.handle.Authority) c.Error!void {
    if (handle.authority != from) return error.Confined;
    if (handle.generation == 0) return error.Io;
    try writer.u32Value(@intFromEnum(to));
    try writer.u32Value(handle.slot);
    try writer.u32Value(handle.generation);
}

fn readHandle(comptime T: type, reader: *Reader, from: semantic.handle.Authority, to: semantic.handle.Authority) c.Error!T {
    const authority: semantic.handle.Authority = @enumFromInt(try reader.u32Value());
    const slot = try reader.u32Value();
    const generation = try reader.u32Value();
    if (authority != from) return error.Confined;
    if (generation == 0) return error.Io;
    return .{ .authority = to, .slot = slot, .generation = generation };
}

fn writeNode(writer: *Writer, node: c.NodeRef, from: semantic.handle.Authority, to: semantic.handle.Authority) !void {
    switch (node) {
        .root => try writer.byte(0),
        .entry => |entry| {
            try writer.byte(1);
            try writeHandle(writer, entry, from, to);
        },
    }
}

fn readNode(reader: *Reader, from: semantic.handle.Authority, to: semantic.handle.Authority) c.Error!c.NodeRef {
    return switch (try reader.byte()) {
        0 => .root,
        1 => .{ .entry = try readHandle(c.EntryRef, reader, from, to) },
        else => error.Io,
    };
}

fn writeRevision(writer: *Writer, revision: c.Revision) !void {
    try writer.bytesValue(revision.token);
}

fn readRevision(reader: *Reader) c.Error!c.Revision {
    return .{ .token = try reader.bytesValue() };
}

fn writeEntrySource(writer: *Writer, source: c.EntrySource, from: semantic.handle.Authority, to: semantic.handle.Authority) !void {
    try writeHandle(writer, source.root, from, to);
    try writeHandle(writer, source.ref, from, to);
    try writeRevision(writer, source.revision);
}

fn readEntrySource(reader: *Reader, from: semantic.handle.Authority, to: semantic.handle.Authority) c.Error!c.EntrySource {
    return .{
        .root = try readHandle(c.Root, reader, from, to),
        .ref = try readHandle(c.EntryRef, reader, from, to),
        .revision = try readRevision(reader),
    };
}

fn writeLeaseSource(writer: *Writer, source: c.LeaseSource, from: semantic.handle.Authority, to: semantic.handle.Authority) !void {
    try writeHandle(writer, source.root, from, to);
    try writeHandle(writer, source.ref, from, to);
}

fn readLeaseSource(reader: *Reader, from: semantic.handle.Authority, to: semantic.handle.Authority) c.Error!c.LeaseSource {
    return .{
        .root = try readHandle(c.Root, reader, from, to),
        .ref = try readHandle(c.LeaseRef, reader, from, to),
    };
}

fn writeSource(writer: *Writer, source: c.Source, from: semantic.handle.Authority, to: semantic.handle.Authority) !void {
    switch (source) {
        .entry => |entry| {
            try writer.byte(0);
            try writeEntrySource(writer, entry, from, to);
        },
        .lease => |lease| {
            try writer.byte(1);
            try writeLeaseSource(writer, lease, from, to);
        },
    }
}

fn readSource(reader: *Reader, from: semantic.handle.Authority, to: semantic.handle.Authority) c.Error!c.Source {
    return switch (try reader.byte()) {
        0 => .{ .entry = try readEntrySource(reader, from, to) },
        1 => .{ .lease = try readLeaseSource(reader, from, to) },
        else => error.Io,
    };
}

fn writeInvalidation(writer: *Writer, invalidation: c.Invalidation, from: semantic.handle.Authority, to: semantic.handle.Authority) !void {
    switch (invalidation) {
        .changed => |entry| {
            try writer.byte(0);
            try writer.boolValue(entry != null);
            if (entry) |ref| try writeHandle(writer, ref, from, to);
        },
        .root_changed => try writer.byte(1),
        .rescan_required => try writer.byte(2),
    }
}

fn readInvalidation(reader: *Reader, from: semantic.handle.Authority, to: semantic.handle.Authority) c.Error!c.Invalidation {
    return switch (try reader.byte()) {
        0 => .{ .changed = if (try reader.boolValue()) try readHandle(c.EntryRef, reader, from, to) else null },
        1 => .root_changed,
        2 => .rescan_required,
        else => error.Io,
    };
}

fn translateHandle(handle: anytype, from: semantic.handle.Authority, to: semantic.handle.Authority) c.Error!void {
    if (handle.authority != from) return error.Confined;
    handle.authority = to;
}

fn translateNode(node: *c.NodeRef, from: semantic.handle.Authority, to: semantic.handle.Authority) c.Error!void {
    switch (node.*) {
        .root => {},
        .entry => |*entry| try translateHandle(entry, from, to),
    }
}

fn translateObservation(observation: *c.Observation, from: semantic.handle.Authority, to: semantic.handle.Authority) c.Error!void {
    try translateNode(&observation.node, from, to);
}

fn translateListing(listing: *c.Listing, from: semantic.handle.Authority, to: semantic.handle.Authority) c.Error!void {
    try translateObservation(&listing.directory, from, to);
    for (@constCast(listing.entries)) |*entry| try translateObservation(&entry.observation, from, to);
}

fn translateEntrySource(source: *c.EntrySource, from: semantic.handle.Authority, to: semantic.handle.Authority) c.Error!void {
    try translateHandle(&source.root, from, to);
    try translateHandle(&source.ref, from, to);
}

fn translateLeaseSource(source: *c.LeaseSource, from: semantic.handle.Authority, to: semantic.handle.Authority) c.Error!void {
    try translateHandle(&source.root, from, to);
    try translateHandle(&source.ref, from, to);
}

fn translateSource(source: *c.Source, from: semantic.handle.Authority, to: semantic.handle.Authority) c.Error!void {
    switch (source.*) {
        .entry => |*entry| try translateEntrySource(entry, from, to),
        .lease => |*lease| try translateLeaseSource(lease, from, to),
    }
}

fn translateParent(parent: *c.ParentRef, from: semantic.handle.Authority, to: semantic.handle.Authority) c.Error!void {
    switch (parent.*) {
        .entry => |*entry| try translateHandle(entry, from, to),
        else => {},
    }
}

fn translateExpected(expected: *c.Expected, from: semantic.handle.Authority, to: semantic.handle.Authority) c.Error!void {
    switch (expected.*) {
        .entry => |*entry| try translateHandle(&entry.ref, from, to),
        else => {},
    }
}

fn translateSlot(slot: *c.Slot, from: semantic.handle.Authority, to: semantic.handle.Authority) c.Error!void {
    try translateParent(&slot.parent, from, to);
}

fn translateOperation(operation: *c.Operation, from: semantic.handle.Authority, to: semantic.handle.Authority) c.Error!void {
    switch (operation.*) {
        .create_file => |*create| {
            try translateSlot(&create.destination, from, to);
            try translateExpected(&create.expected, from, to);
        },
        .create_directory => |*create| {
            try translateSlot(&create.destination, from, to);
            try translateExpected(&create.expected, from, to);
        },
        .create_symlink => |*create| {
            try translateSlot(&create.destination, from, to);
            try translateExpected(&create.expected, from, to);
        },
        .copy => |*copy| {
            try translateSource(&copy.source, from, to);
            try translateSlot(&copy.destination, from, to);
            try translateExpected(&copy.expected, from, to);
        },
        .rename => |*rename| {
            try translateEntrySource(&rename.source, from, to);
            try translateSlot(&rename.destination, from, to);
            try translateExpected(&rename.expected, from, to);
        },
        .remove => |*remove| try translateEntrySource(&remove.source, from, to),
        .set_permissions => |*permissions| try translateEntrySource(&permissions.source, from, to),
    }
}

fn translatePlan(plan: *c.Plan, from: semantic.handle.Authority, to: semantic.handle.Authority) c.Error!void {
    try translateHandle(&plan.root, from, to);
    for (@constCast(plan.operations)) |*planned| try translateOperation(&planned.operation, from, to);
}

fn translateOutcome(outcome: *c.Outcome, from: semantic.handle.Authority, to: semantic.handle.Authority) c.Error!void {
    switch (outcome.*) {
        .applied => |*observation| if (observation.*) |*value| try translateObservation(value, from, to),
        .recoverable_at => |*slot| try translateSlot(slot, from, to),
        else => {},
    }
}

fn translateReport(report: *c.ApplyReport, from: semantic.handle.Authority, to: semantic.handle.Authority) c.Error!void {
    for (@constCast(report.entries)) |*entry| try translateOutcome(&entry.outcome, from, to);
}

fn cloneObservation(arena: std.mem.Allocator, observation: c.Observation) !c.Observation {
    var result = observation;
    result.revision.token = try arena.dupe(u8, observation.revision.token);
    if (observation.metadata.link_target) |target| result.metadata.link_target = try arena.dupe(u8, target);
    return result;
}

fn cloneListing(arena: std.mem.Allocator, listing: c.Listing) !c.Listing {
    const entries = try arena.alloc(c.DirEntry, listing.entries.len);
    for (entries, listing.entries) |*destination, source| {
        destination.* = source;
        destination.name = c.Name.init(try arena.dupe(u8, source.name.bytes)) catch unreachable;
        destination.observation = try cloneObservation(arena, source.observation);
    }
    return .{
        .directory = try cloneObservation(arena, listing.directory),
        .revision = .{ .token = try arena.dupe(u8, listing.revision.token) },
        .entries = entries,
    };
}

const OwnedPlanClone = struct {
    arena: std.heap.ArenaAllocator,
    value: c.Plan,
    fn deinit(self: *OwnedPlanClone) void {
        self.arena.deinit();
    }
};

fn clonePlan(gpa: std.mem.Allocator, plan: c.Plan) !OwnedPlanClone {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const operations = try arena.allocator().alloc(c.Planned, plan.operations.len);
    @memcpy(operations, plan.operations);
    return .{ .arena = arena, .value = .{ .root = plan.root, .base_revision = plan.base_revision, .operations = operations } };
}

fn cloneReport(arena: std.mem.Allocator, report: c.ApplyReport) !c.ApplyReport {
    const entries = try arena.alloc(c.ReportEntry, report.entries.len);
    for (entries, report.entries) |*destination, source| {
        destination.* = source;
        switch (source.outcome) {
            .applied => |observation| {
                if (observation) |value| destination.outcome = .{ .applied = try cloneObservation(arena, value) };
            },
            .conflict => |message| destination.outcome = .{ .conflict = try arena.dupe(u8, message) },
            .ambiguous => |message| destination.outcome = .{ .ambiguous = try arena.dupe(u8, message) },
            else => {},
        }
    }
    return .{ .entries = entries };
}

fn readOnlyCapabilities(capabilities: c.Capabilities) c.Capabilities {
    var result = capabilities;
    result.exclusive_create = false;
    result.atomic_exchange = false;
    result.quarantine = false;
    result.clone_acceleration = false;
    result.posix_mode = false;
    return result;
}

fn handleKey(handle: anytype) u128 {
    return (@as(u128, @intFromEnum(handle.authority)) << 64) |
        (@as(u128, handle.slot) << 32) |
        @as(u128, handle.generation);
}

const TestProvider = struct {
    authority: semantic.handle.Authority = @enumFromInt(9),
    stale: bool = false,
    applied: bool = false,
    released_roots: usize = 0,
    released_leases: usize = 0,
    closed_watches: usize = 0,

    fn service(self: *TestProvider) fs.service.Provider {
        return .init(self);
    }

    pub fn capabilities(_: *TestProvider, _: c.Root) c.Error!c.Capabilities {
        return .{ .exclusive_create = true, .symlink = true, .posix_mode = true, .watch = .invalidation };
    }
    pub fn sameRoot(_: *TestProvider, left: c.Root, right: c.Root) c.Error!bool {
        return left.eql(right);
    }
    pub fn deriveRoot(_: *TestProvider, source: c.EntrySource) c.Error!c.Root {
        if (!std.mem.eql(u8, source.revision.token, "entry-r1")) return error.Stale;
        return .{ .authority = source.root.authority, .slot = 2, .generation = 1 };
    }
    pub fn releaseRoot(self: *TestProvider, _: c.Root) void {
        self.released_roots += 1;
    }
    pub fn observe(self: *TestProvider, gpa: std.mem.Allocator, _: c.Root, node: c.NodeRef) c.Error!c.OwnedObservation {
        if (self.stale) return error.Stale;
        var result = c.OwnedObservation.init(gpa);
        result.value = .{ .node = node, .revision = .{ .token = "root-r1" }, .kind = .directory };
        return result;
    }
    pub fn list(self: *TestProvider, gpa: std.mem.Allocator, root: c.Root, node: c.NodeRef) c.Error!c.OwnedListing {
        if (self.stale) return error.Stale;
        var result = c.OwnedListing.init(gpa);
        const entries = try result.allocator().alloc(c.DirEntry, 2);
        entries[0] = .{
            .name = c.Name.init(try result.allocator().dupe(u8, &[_]u8{ 'o', 'd', 'd', '\n', 0xff })) catch unreachable,
            .observation = .{
                .node = .{ .entry = .{ .authority = self.authority, .slot = 4, .generation = 1 } },
                .revision = .{ .token = "entry-r1" },
                .kind = .directory,
            },
        };
        entries[1] = .{
            .name = c.Name.init("link") catch unreachable,
            .observation = .{
                .node = .{ .entry = .{ .authority = self.authority, .slot = 5, .generation = 1 } },
                .revision = .{ .token = "link-r1" },
                .kind = .symlink,
                .metadata = .{ .link_target = "../outside-looking-but-not-followed" },
            },
        };
        result.value = .{
            .directory = .{ .node = node, .revision = .{ .token = "root-r1" }, .kind = .directory },
            .revision = .{ .token = "listing-r1" },
            .entries = entries,
        };
        _ = root;
        return result;
    }
    pub fn read(_: *TestProvider, gpa: std.mem.Allocator, request: c.ReadRequest) c.Error!c.OwnedReadResult {
        var result = c.OwnedReadResult.init(gpa);
        const node: c.NodeRef = switch (request.source) {
            .entry => |entry| .{ .entry = entry.ref },
            .lease => .root,
        };
        result.value = .{ .observation = .{ .node = node, .revision = .{ .token = "read-r1" }, .kind = .regular }, .bytes = "bytes", .eof = true };
        return result;
    }
    pub fn capture(self: *TestProvider, _: c.EntrySource) c.Error!c.LeaseRef {
        return .{ .authority = self.authority, .slot = 6, .generation = 1 };
    }
    pub fn releaseLease(self: *TestProvider, _: c.LeaseSource) void {
        self.released_leases += 1;
    }
    pub fn apply(self: *TestProvider, gpa: std.mem.Allocator, plan: c.Plan) c.Error!c.OwnedApplyReport {
        self.applied = true;
        var result = c.OwnedApplyReport.init(gpa);
        const entries = try result.allocator().alloc(c.ReportEntry, plan.operations.len);
        for (entries, plan.operations) |*entry, planned| entry.* = .{ .id = planned.id, .outcome = .{ .applied = null } };
        result.value = .{ .entries = entries };
        return result;
    }
    pub fn watch(self: *TestProvider, _: c.Root, _: c.NodeRef, _: bool) c.Error!c.WatchRef {
        return .{ .authority = self.authority, .slot = 7, .generation = 1 };
    }
    pub fn pollInvalidation(self: *TestProvider, _: c.WatchRef) c.Error!?c.Invalidation {
        return .{ .changed = .{ .authority = self.authority, .slot = 4, .generation = 1 } };
    }
    pub fn closeWatch(self: *TestProvider, _: c.WatchRef) void {
        self.closed_watches += 1;
    }
};

const Loopback = struct {
    server: *Server,
    pub fn roundTrip(self: *Loopback, gpa: std.mem.Allocator, request: []const u8) c.Error![]u8 {
        return self.server.handle(gpa, request);
    }
};

fn wireRoot(root: c.Root) c.Root {
    return .{ .authority = wire_authority, .slot = root.slot, .generation = root.generation };
}

fn wireLease(source: c.LeaseSource) c.LeaseSource {
    return .{ .root = wireRoot(source.root), .ref = .{ .authority = wire_authority, .slot = source.ref.slot, .generation = source.ref.generation } };
}

fn wireWatch(watch: c.WatchRef) c.WatchRef {
    return .{ .authority = wire_authority, .slot = watch.slot, .generation = watch.generation };
}

fn requestStatus(gpa: std.mem.Allocator, server: *Server, request: *Writer) !Status {
    const bytes = try request.finish();
    defer gpa.free(bytes);
    const response = try server.handle(gpa, bytes);
    defer gpa.free(response);
    var reader = try Reader.init(response);
    const status = try reader.responseHeader();
    try reader.done();
    return status;
}

test "remote provider preserves opaque authority raw names symlinks guards and mutations" {
    const gpa = std.testing.allocator;
    var implementation: TestProvider = .{};
    const server_root: c.Root = .{ .authority = implementation.authority, .slot = 1, .generation = 1 };
    var server = try Server.init(gpa, implementation.service(), server_root, .read_write);
    defer server.deinit();
    var loopback: Loopback = .{ .server = &server };
    const remote_authority: semantic.handle.Authority = @enumFromInt(41);
    var remote = try Provider.init(remote_authority, .init(&loopback));
    const root = try remote.acquireRoot();
    try std.testing.expectEqual(remote_authority, root.authority);

    var listing = try remote.list(gpa, root, .root);
    defer listing.deinit();
    try std.testing.expectEqualStrings(&[_]u8{ 'o', 'd', 'd', '\n', 0xff }, listing.value.entries[0].name.bytes);
    try std.testing.expectEqual(remote_authority, listing.value.entries[0].observation.node.entry.authority);
    try std.testing.expectEqual(c.Kind.symlink, listing.value.entries[1].observation.kind);
    try std.testing.expectEqualStrings("../outside-looking-but-not-followed", listing.value.entries[1].observation.metadata.link_target.?);

    const child = try remote.deriveRoot(.{
        .root = root,
        .ref = listing.value.entries[0].observation.node.entry,
        .revision = listing.value.entries[0].observation.revision,
    });
    try std.testing.expectEqual(remote_authority, child.authority);

    const operation: c.Planned = .{
        .id = [_]u8{1} ** 16,
        .operation = .{ .create_file = .{ .destination = .{ .parent = .root, .name = try c.Name.init("new") }, .contents = "value" } },
    };
    var report = try remote.apply(gpa, .{ .root = child, .base_revision = "listing-r1", .operations = &.{operation} });
    defer report.deinit();
    try std.testing.expect(implementation.applied);
    try std.testing.expectEqual(@as(usize, 1), report.value.entries.len);

    implementation.stale = true;
    try std.testing.expectError(error.Stale, remote.list(gpa, root, .root));
}

test "read-only remote provider advertises and enforces the same policy" {
    const gpa = std.testing.allocator;
    var implementation: TestProvider = .{};
    const server_root: c.Root = .{ .authority = implementation.authority, .slot = 1, .generation = 1 };
    var server = try Server.init(gpa, implementation.service(), server_root, .read);
    defer server.deinit();
    var loopback: Loopback = .{ .server = &server };
    var remote = try Provider.init(@enumFromInt(42), .init(&loopback));
    const root = try remote.acquireRoot();
    const capabilities = try remote.capabilities(root);
    try std.testing.expect(!capabilities.exclusive_create);
    try std.testing.expect(!capabilities.posix_mode);
    const operation: c.Planned = .{
        .id = [_]u8{2} ** 16,
        .operation = .{ .create_file = .{ .destination = .{ .parent = .root, .name = try c.Name.init("denied") }, .contents = "" } },
    };
    try std.testing.expectError(error.PermissionDenied, remote.apply(gpa, .{ .root = root, .base_revision = "", .operations = &.{operation} }));
    try std.testing.expect(!implementation.applied);
}

test "remote server rejects foreign and already-released derived handles" {
    const gpa = std.testing.allocator;
    var implementation: TestProvider = .{};
    const server_root: c.Root = .{ .authority = implementation.authority, .slot = 1, .generation = 1 };
    var first_server = try Server.init(gpa, implementation.service(), server_root, .read_write);
    defer first_server.deinit();
    var second_server = try Server.init(gpa, implementation.service(), server_root, .read_write);
    defer second_server.deinit();

    var first_loopback: Loopback = .{ .server = &first_server };
    var first_remote = try Provider.init(@enumFromInt(43), .init(&first_loopback));
    const first_root = try first_remote.acquireRoot();
    var listing = try first_remote.list(gpa, first_root, .root);
    defer listing.deinit();
    const child = try first_remote.deriveRoot(.{
        .root = first_root,
        .ref = listing.value.entries[0].observation.node.entry,
        .revision = listing.value.entries[0].observation.revision,
    });

    var foreign_release = try beginRequest(gpa, .release_root);
    defer foreign_release.deinit();
    try writeHandle(&foreign_release, wireRoot(child), wire_authority, wire_authority);
    try std.testing.expectEqual(Status.confined, try requestStatus(gpa, &second_server, &foreign_release));

    var foreign_list = try beginRequest(gpa, .list);
    defer foreign_list.deinit();
    try writeHandle(&foreign_list, wireRoot(child), wire_authority, wire_authority);
    try writeNode(&foreign_list, .root, wire_authority, wire_authority);
    try std.testing.expectEqual(Status.confined, try requestStatus(gpa, &second_server, &foreign_list));

    first_remote.releaseRoot(child);
    var stale_release = try beginRequest(gpa, .release_root);
    defer stale_release.deinit();
    try writeHandle(&stale_release, wireRoot(child), wire_authority, wire_authority);
    try std.testing.expectEqual(Status.confined, try requestStatus(gpa, &first_server, &stale_release));

    var stale_list = try beginRequest(gpa, .list);
    defer stale_list.deinit();
    try writeHandle(&stale_list, wireRoot(child), wire_authority, wire_authority);
    try writeNode(&stale_list, .root, wire_authority, wire_authority);
    try std.testing.expectEqual(Status.confined, try requestStatus(gpa, &first_server, &stale_list));

    const lease = try first_remote.capture(.{
        .root = first_root,
        .ref = listing.value.entries[0].observation.node.entry,
        .revision = listing.value.entries[0].observation.revision,
    });
    const lease_source: c.LeaseSource = .{ .root = first_root, .ref = lease };
    var foreign_lease_release = try beginRequest(gpa, .release_lease);
    defer foreign_lease_release.deinit();
    try writeLeaseSource(&foreign_lease_release, wireLease(lease_source), wire_authority, wire_authority);
    try std.testing.expectEqual(Status.confined, try requestStatus(gpa, &second_server, &foreign_lease_release));

    var foreign_lease_read = try beginRequest(gpa, .read);
    defer foreign_lease_read.deinit();
    try writeSource(&foreign_lease_read, .{ .lease = wireLease(lease_source) }, wire_authority, wire_authority);
    try foreign_lease_read.u64Value(0);
    try foreign_lease_read.boolValue(false);
    try std.testing.expectEqual(Status.confined, try requestStatus(gpa, &second_server, &foreign_lease_read));
    first_remote.releaseLease(lease_source);

    var stale_lease_read = try beginRequest(gpa, .read);
    defer stale_lease_read.deinit();
    try writeSource(&stale_lease_read, .{ .lease = wireLease(lease_source) }, wire_authority, wire_authority);
    try stale_lease_read.u64Value(0);
    try stale_lease_read.boolValue(false);
    try std.testing.expectEqual(Status.confined, try requestStatus(gpa, &first_server, &stale_lease_read));

    const watch = try first_remote.watch(first_root, .root, false);
    var foreign_poll = try beginRequest(gpa, .poll_invalidation);
    defer foreign_poll.deinit();
    try writeHandle(&foreign_poll, wireWatch(watch), wire_authority, wire_authority);
    try std.testing.expectEqual(Status.confined, try requestStatus(gpa, &second_server, &foreign_poll));
    first_remote.closeWatch(watch);

    var stale_watch_close = try beginRequest(gpa, .close_watch);
    defer stale_watch_close.deinit();
    try writeHandle(&stale_watch_close, wireWatch(watch), wire_authority, wire_authority);
    try std.testing.expectEqual(Status.confined, try requestStatus(gpa, &first_server, &stale_watch_close));
}

test "remote server teardown drains roots leases and watches" {
    const gpa = std.testing.allocator;
    var implementation: TestProvider = .{};
    const server_root: c.Root = .{ .authority = implementation.authority, .slot = 1, .generation = 1 };
    var server = try Server.init(gpa, implementation.service(), server_root, .read_write);
    var loopback: Loopback = .{ .server = &server };
    var remote = try Provider.init(@enumFromInt(44), .init(&loopback));
    const root = try remote.acquireRoot();
    var listing = try remote.list(gpa, root, .root);
    defer listing.deinit();
    _ = try remote.deriveRoot(.{
        .root = root,
        .ref = listing.value.entries[0].observation.node.entry,
        .revision = listing.value.entries[0].observation.revision,
    });
    _ = try remote.capture(.{
        .root = root,
        .ref = listing.value.entries[0].observation.node.entry,
        .revision = listing.value.entries[0].observation.revision,
    });
    _ = try remote.watch(root, .root, true);

    server.deinit();
    try std.testing.expectEqual(@as(usize, 1), implementation.released_roots);
    try std.testing.expectEqual(@as(usize, 1), implementation.released_leases);
    try std.testing.expectEqual(@as(usize, 1), implementation.closed_watches);
}
