//! Pure candidate-health gate for station activation.
const std = @import("std");
const identity = @import("station_identity.zig");
const effects = @import("host_effects.zig");
const protocol = @import("station_protocol.zig");

pub const HealthFailure = enum { offline, @"auth-required", @"vault-unavailable", health_failed };
pub const HealthOutcome = union(enum) { healthy, failed: HealthFailure };

pub const Activation = struct {
    operation_id: u64,
    old_generation: u64,
    new_generation: u64,
    old_station: ?identity.StationIdentity,
    new_station: identity.StationIdentity,
};

pub const Resolution = union(enum) {
    stale,
    failed: protocol.OperationStatus,
    activated: Activation,
};

pub const Cancelled = struct { operation_id: u64, request_id: ?u64 };

const Candidate = struct {
    station: identity.StationIdentity,
    operation_id: u64,
    generation: u64,
    request: ?effects.RequestTag = null,
};

pub const Coordinator = struct {
    active_station: ?identity.StationIdentity = null,
    generation: u64 = 0,
    next_operation_id: u64 = 1,
    candidate: ?Candidate = null,
    latest_station_operation: ?protocol.OperationStatus = null,

    pub const Begun = struct {
        operation_id: u64,
        generation: u64,
        station: identity.StationIdentity,
    };

    pub fn begin(self: *Coordinator, address: []const u8) !Begun {
        if (self.candidate != null) return error.Busy;
        if (self.next_operation_id == 0 or self.next_operation_id > protocol.max_operation_id) return error.IdentityExhausted;
        if (self.generation >= protocol.max_operation_id) return error.IdentityExhausted;
        var station: identity.StationIdentity = .{};
        _ = try identity.normalizeStation(address, &station);
        const operation_id = self.next_operation_id;
        self.next_operation_id += 1;
        const candidate_generation = self.generation + 1;
        self.candidate = .{ .station = station, .operation_id = operation_id, .generation = candidate_generation };
        self.latest_station_operation = .{ .operationId = operation_id, .status = .pending };
        return .{ .operation_id = operation_id, .generation = candidate_generation, .station = station };
    }

    /// Binds the exact request returned by the HTTP owner. A candidate cannot
    /// activate until this succeeds, and it may be bound only once.
    pub fn attachRequest(self: *Coordinator, operation_id: u64, request_tag: effects.RequestTag) !void {
        const candidate = if (self.candidate) |*value| value else return error.NoCandidate;
        if (candidate.operation_id != operation_id or request_tag.operation_id != operation_id or
            request_tag.generation != candidate.generation or request_tag.request_id == 0 or request_tag.kind != .health)
            return error.InvalidRequestTag;
        if (candidate.request != null) return error.RequestAlreadyAttached;
        candidate.request = request_tag;
    }

    /// Invalidates the candidate before returning the request identity that
    /// the owner should cancel. A later completion therefore resolves stale.
    pub fn cancel(self: *Coordinator, operation_id: u64) !Cancelled {
        const candidate = self.candidate orelse return error.NoCandidate;
        if (candidate.operation_id != operation_id) return error.OperationMismatch;
        self.candidate = null;
        self.latest_station_operation = .{ .operationId = operation_id, .status = .failed, .errorCode = "cancelled" };
        return .{ .operation_id = operation_id, .request_id = if (candidate.request) |tag| tag.request_id else null };
    }

    pub fn resolve(self: *Coordinator, request_tag: effects.RequestTag, outcome: HealthOutcome) Resolution {
        const candidate = self.candidate orelse return .stale;
        const expected = candidate.request orelse return .stale;
        if (!sameTag(expected, request_tag)) return .stale;
        self.candidate = null;
        switch (outcome) {
            .failed => |failure| {
                const status: protocol.OperationStatus = .{ .operationId = candidate.operation_id, .status = .failed, .errorCode = @tagName(failure) };
                self.latest_station_operation = status;
                return .{ .failed = status };
            },
            .healthy => {
                const activation: Activation = .{
                    .operation_id = candidate.operation_id,
                    .old_generation = self.generation,
                    .new_generation = candidate.generation,
                    .old_station = self.active_station,
                    .new_station = candidate.station,
                };
                self.active_station = candidate.station;
                self.generation = candidate.generation;
                self.latest_station_operation = .{ .operationId = candidate.operation_id, .status = .succeeded };
                return .{ .activated = activation };
            },
        }
    }

    pub fn pendingOperation(self: *const Coordinator) ?protocol.OperationStatus {
        return self.latest_station_operation;
    }
};

fn sameTag(a: effects.RequestTag, b: effects.RequestTag) bool {
    return a.operation_id == b.operation_id and a.generation == b.generation and
        a.request_id == b.request_id and a.kind == b.kind;
}

fn makeTag(begin: Coordinator.Begun, request_id: u64) effects.RequestTag {
    return .{ .operation_id = begin.operation_id, .generation = begin.generation, .request_id = request_id, .kind = .health };
}

fn expectActive(coordinator: *const Coordinator, base: []const u8) !void {
    try std.testing.expectEqualStrings(base, coordinator.active_station.?.base());
}

test "health success activates and failure preserves active station" {
    var coordinator: Coordinator = .{};
    const a = try coordinator.begin("a.example");
    const a_tag = makeTag(a, 101);
    try coordinator.attachRequest(a.operation_id, a_tag);
    const activated_a = coordinator.resolve(a_tag, .healthy).activated;
    try std.testing.expect(activated_a.old_station == null);
    try std.testing.expectEqual(@as(u64, 1), coordinator.generation);
    try expectActive(&coordinator, "https://a.example");

    const b = try coordinator.begin("b.example");
    const b_tag = makeTag(b, 102);
    try coordinator.attachRequest(b.operation_id, b_tag);
    const failed = coordinator.resolve(b_tag, .{ .failed = .offline }).failed;
    try std.testing.expectEqual(protocol.OperationState.failed, failed.status);
    try expectActive(&coordinator, "https://a.example");
    try std.testing.expectEqual(@as(u64, 1), coordinator.generation);
}

test "busy cancel rapid connect and late old health cannot activate" {
    var coordinator: Coordinator = .{};
    const a = try coordinator.begin("a.example");
    const a_tag = makeTag(a, 201);
    try coordinator.attachRequest(a.operation_id, a_tag);
    try std.testing.expectError(error.Busy, coordinator.begin("b.example"));
    const cancelled = try coordinator.cancel(a.operation_id);
    try std.testing.expectEqual(@as(?u64, 201), cancelled.request_id);

    const b = try coordinator.begin("b.example");
    const b_tag = makeTag(b, 202);
    try coordinator.attachRequest(b.operation_id, b_tag);
    try std.testing.expect(coordinator.resolve(a_tag, .healthy) == .stale);
    try std.testing.expect(coordinator.active_station == null);
    _ = coordinator.resolve(b_tag, .healthy).activated;
    try expectActive(&coordinator, "https://b.example");
    try std.testing.expectEqual(@as(u64, 1), coordinator.generation);
}

test "activation requires the full attached health request tag" {
    var coordinator: Coordinator = .{};
    const begun = try coordinator.begin("a.example");
    const expected = makeTag(begun, 301);
    try std.testing.expectError(error.InvalidRequestTag, coordinator.attachRequest(begun.operation_id, .{ .operation_id = begun.operation_id, .generation = begun.generation, .request_id = 301, .kind = .state }));
    try coordinator.attachRequest(begun.operation_id, expected);
    try std.testing.expect(coordinator.resolve(.{ .operation_id = expected.operation_id, .generation = expected.generation, .request_id = 302, .kind = .health }, .healthy) == .stale);
    try std.testing.expect(coordinator.resolve(.{ .operation_id = expected.operation_id, .generation = expected.generation + 1, .request_id = expected.request_id, .kind = .health }, .healthy) == .stale);
    try std.testing.expect(coordinator.active_station == null);
    _ = coordinator.resolve(expected, .healthy).activated;
    try expectActive(&coordinator, "https://a.example");
}

test "operation and generation identities stop at JavaScript safe integers" {
    var operation_exhausted: Coordinator = .{ .next_operation_id = protocol.max_operation_id + 1 };
    try std.testing.expectError(error.IdentityExhausted, operation_exhausted.begin("a.example"));
    var generation_exhausted: Coordinator = .{ .generation = protocol.max_operation_id };
    try std.testing.expectError(error.IdentityExhausted, generation_exhausted.begin("a.example"));
}
