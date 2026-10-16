//! Pure, serialized station-forget transaction coordinator.
const std = @import("std");
const protocol = @import("station_protocol.zig");
const preferences = @import("preferences.zig");
const vault = @import("credential_vault.zig");

pub const FileResult = struct { operation_id: u64, request_id: u64, outcome: Outcome };
pub const VaultResult = struct { operation_id: u64, request_id: u64, outcome: Outcome };
pub const Outcome = enum { ok, miss, locked, denied, io_failed, rejected, cancelled };

pub const FileCommand = struct {
    operation_id: u64,
    request_id: u64,
    storage: [preferences.max_output_bytes]u8 = undefined,
    len: u16 = 0,
    pub fn bytes(self: *const FileCommand) []const u8 {
        return self.storage[0..self.len];
    }
};
pub const VaultCommand = struct {
    operation_id: u64,
    request_id: u64,
    key_storage: [vault.max_key_bytes]u8 = undefined,
    key_len: u16 = 0,
    pub fn key(self: *const VaultCommand) []const u8 {
        return self.key_storage[0..self.key_len];
    }
};
pub const Failure = enum { save_failed, vault_locked, vault_denied, vault_io_failed, vault_rejected, cancelled };
pub const Step = union(enum) { file: FileCommand, vault: VaultCommand, succeeded, failed: Failure, stale };

const Phase = enum { idle, marking, deleting_basic, deleting_listener, final_save, succeeded, failed };

pub const Transaction = struct {
    allocator: std.mem.Allocator,
    phase: Phase = .idle,
    operation_id: u64 = 0,
    next_request_id: u64 = 1,
    expected_request_id: u64 = 0,
    working: ?preferences.Decoded = null,

    pub fn init(allocator: std.mem.Allocator) Transaction {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Transaction) void {
        if (self.working) |*working| working.deinit();
        self.* = undefined;
    }

    pub fn begin(self: *Transaction, operation_id: u64, current: preferences.Preferences, station_id: []const u8) !Step {
        if (self.phase != .idle) return error.Busy;
        if (operation_id == 0 or operation_id > protocol.max_operation_id) return error.InvalidOperation;
        if (station_id.len != 64) return error.InvalidStation;
        if (current.pendingRemoval) |pending| {
            if (!std.mem.eql(u8, pending, station_id)) return error.Busy;
        } else {
            var found = false;
            for (current.stations) |station| found = found or std.mem.eql(u8, station.id, station_id);
            if (!found) return error.UnknownStation;
        }

        self.working = try clonePreferences(self.allocator, current);
        self.operation_id = operation_id;
        if (self.working.?.value.pendingRemoval != null) return self.issueDelete(.basic);
        self.working.?.value.pendingRemoval = try self.working.?.arena.allocator().dupe(u8, station_id);
        self.phase = .marking;
        return self.issueSave();
    }

    pub fn onFile(self: *Transaction, result: FileResult) Step {
        if (result.operation_id != self.operation_id or result.request_id != self.expected_request_id) return .stale;
        return switch (self.phase) {
            .marking => if (result.outcome == .ok) self.issueDelete(.basic) else self.fail(fileFailure(result.outcome)),
            .final_save => if (result.outcome == .ok) blk: {
                self.phase = .succeeded;
                break :blk .succeeded;
            } else self.fail(fileFailure(result.outcome)),
            else => .stale,
        };
    }

    pub fn onVault(self: *Transaction, result: VaultResult) Step {
        if (result.operation_id != self.operation_id or result.request_id != self.expected_request_id) return .stale;
        if (result.outcome != .ok and result.outcome != .miss) return self.fail(vaultFailure(result.outcome));
        return switch (self.phase) {
            .deleting_basic => self.issueDelete(.listener),
            .deleting_listener => self.finishRemoval(),
            else => .stale,
        };
    }

    pub fn takeSucceeded(self: *Transaction) !preferences.Decoded {
        if (self.phase != .succeeded) return error.NotSucceeded;
        const result = self.working orelse return error.NotSucceeded;
        self.working = null;
        self.phase = .idle;
        self.operation_id = 0;
        return result;
    }

    fn issueSave(self: *Transaction) Step {
        const request_id = self.reserveRequest() catch return self.fail(.save_failed);
        var command: FileCommand = .{ .operation_id = self.operation_id, .request_id = request_id };
        const bytes = preferences.encode(self.working.?.value, &command.storage) catch return self.fail(.save_failed);
        command.len = @intCast(bytes.len);
        return .{ .file = command };
    }

    fn issueDelete(self: *Transaction, kind: vault.Kind) Step {
        const request_id = self.reserveRequest() catch return self.fail(.vault_rejected);
        var command: VaultCommand = .{ .operation_id = self.operation_id, .request_id = request_id };
        const key = vault.writeKey(kind, self.working.?.value.pendingRemoval.?, &command.key_storage) catch return self.fail(.vault_rejected);
        command.key_len = @intCast(key.len);
        self.phase = if (kind == .basic) .deleting_basic else .deleting_listener;
        return .{ .vault = command };
    }

    fn finishRemoval(self: *Transaction) Step {
        const working = &self.working.?;
        const removal = working.value.pendingRemoval.?;
        const next = working.arena.allocator().alloc(preferences.Station, working.value.stations.len - 1) catch return self.fail(.save_failed);
        var index: usize = 0;
        for (working.value.stations) |station| {
            if (std.mem.eql(u8, station.id, removal)) continue;
            next[index] = station;
            index += 1;
        }
        working.value.stations = next[0..index];
        if (working.value.activeStationId) |active| {
            if (std.mem.eql(u8, active, removal)) working.value.activeStationId = null;
        }
        working.value.pendingRemoval = null;
        self.phase = .final_save;
        return self.issueSave();
    }

    fn reserveRequest(self: *Transaction) !u64 {
        if (self.next_request_id == 0 or self.next_request_id > protocol.max_operation_id) return error.IdentityExhausted;
        const result = self.next_request_id;
        self.next_request_id += 1;
        self.expected_request_id = result;
        return result;
    }
    fn fail(self: *Transaction, failure: Failure) Step {
        self.phase = .failed;
        return .{ .failed = failure };
    }
};

fn clonePreferences(allocator: std.mem.Allocator, value: preferences.Preferences) !preferences.Decoded {
    var bytes: [preferences.max_output_bytes]u8 = undefined;
    return preferences.decode(allocator, try preferences.encode(value, &bytes));
}
fn fileFailure(outcome: Outcome) Failure {
    return if (outcome == .cancelled) .cancelled else .save_failed;
}
fn vaultFailure(outcome: Outcome) Failure {
    return switch (outcome) {
        .locked => .vault_locked,
        .denied => .vault_denied,
        .io_failed => .vault_io_failed,
        .cancelled => .cancelled,
        else => .vault_rejected,
    };
}

fn fixture() !struct { identity: @import("station_identity.zig").StationIdentity, decoded: preferences.Decoded } {
    var identity: @import("station_identity.zig").StationIdentity = .{};
    _ = try @import("station_identity.zig").normalizeStation("radio.example", &identity);
    var body: [1024]u8 = undefined;
    const json = try std.fmt.bufPrint(&body, "{{\"version\":2,\"activeStationId\":\"{s}\",\"stations\":[{{\"id\":\"{s}\",\"base\":\"{s}\",\"name\":\"Radio\"}}]}}", .{ &identity.id, &identity.id, identity.base() });
    return .{ .identity = identity, .decoded = try preferences.decode(std.testing.allocator, json) };
}

test "forget persists marker before idempotent credential deletes and final removal" {
    var f = try fixture();
    defer f.decoded.deinit();
    var transaction = Transaction.init(std.testing.allocator);
    defer transaction.deinit();
    const mark = (try transaction.begin(7, f.decoded.value, &f.identity.id)).file;
    var marked = try preferences.decode(std.testing.allocator, mark.bytes());
    defer marked.deinit();
    try std.testing.expectEqualStrings(&f.identity.id, marked.value.pendingRemoval.?);
    const basic = transaction.onFile(.{ .operation_id = 7, .request_id = mark.request_id, .outcome = .ok }).vault;
    try std.testing.expect(std.mem.startsWith(u8, basic.key(), "basic:"));
    const listener = transaction.onVault(.{ .operation_id = 7, .request_id = basic.request_id, .outcome = .miss }).vault;
    const final = transaction.onVault(.{ .operation_id = 7, .request_id = listener.request_id, .outcome = .ok }).file;
    var saved = try preferences.decode(std.testing.allocator, final.bytes());
    defer saved.deinit();
    try std.testing.expectEqual(@as(usize, 0), saved.value.stations.len);
    try std.testing.expect(saved.value.activeStationId == null and saved.value.pendingRemoval == null);
    try std.testing.expect(transaction.onFile(.{ .operation_id = 7, .request_id = final.request_id, .outcome = .ok }) == .succeeded);
    var result = try transaction.takeSucceeded();
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.value.stations.len);
}

test "restart from durable marker skips marker save and retries both deletes" {
    var f = try fixture();
    defer f.decoded.deinit();
    f.decoded.value.pendingRemoval = &f.identity.id;
    var transaction = Transaction.init(std.testing.allocator);
    defer transaction.deinit();
    const first = (try transaction.begin(8, f.decoded.value, &f.identity.id)).vault;
    try std.testing.expect(std.mem.startsWith(u8, first.key(), "basic:"));
    const second = transaction.onVault(.{ .operation_id = 8, .request_id = first.request_id, .outcome = .miss }).vault;
    try std.testing.expect(std.mem.startsWith(u8, second.key(), "listener:"));
}

test "delete and final save failures retain the durable listed marker contract" {
    {
        var f = try fixture();
        defer f.decoded.deinit();
        var transaction = Transaction.init(std.testing.allocator);
        defer transaction.deinit();
        const mark = (try transaction.begin(9, f.decoded.value, &f.identity.id)).file;
        try std.testing.expect(transaction.onFile(.{ .operation_id = 9, .request_id = mark.request_id, .outcome = .io_failed }) == .failed);
    }
    inline for (.{ Outcome.locked, Outcome.denied, Outcome.io_failed }) |outcome| {
        var f = try fixture();
        defer f.decoded.deinit();
        var transaction = Transaction.init(std.testing.allocator);
        defer transaction.deinit();
        const mark = (try transaction.begin(9, f.decoded.value, &f.identity.id)).file;
        const basic = transaction.onFile(.{ .operation_id = 9, .request_id = mark.request_id, .outcome = .ok }).vault;
        try std.testing.expect(transaction.onVault(.{ .operation_id = 9, .request_id = basic.request_id, .outcome = outcome }) == .failed);
    }
    {
        var f = try fixture();
        defer f.decoded.deinit();
        var transaction = Transaction.init(std.testing.allocator);
        defer transaction.deinit();
        const mark = (try transaction.begin(12, f.decoded.value, &f.identity.id)).file;
        const basic = transaction.onFile(.{ .operation_id = 12, .request_id = mark.request_id, .outcome = .ok }).vault;
        const listener = transaction.onVault(.{ .operation_id = 12, .request_id = basic.request_id, .outcome = .ok }).vault;
        try std.testing.expect(transaction.onVault(.{ .operation_id = 12, .request_id = listener.request_id, .outcome = .locked }) == .failed);
    }
    {
        var f = try fixture();
        defer f.decoded.deinit();
        var transaction = Transaction.init(std.testing.allocator);
        defer transaction.deinit();
        const mark = (try transaction.begin(13, f.decoded.value, &f.identity.id)).file;
        const basic = transaction.onFile(.{ .operation_id = 13, .request_id = mark.request_id, .outcome = .ok }).vault;
        const listener = transaction.onVault(.{ .operation_id = 13, .request_id = basic.request_id, .outcome = .miss }).vault;
        const final = transaction.onVault(.{ .operation_id = 13, .request_id = listener.request_id, .outcome = .miss }).file;
        try std.testing.expect(transaction.onFile(.{ .operation_id = 13, .request_id = final.request_id, .outcome = .io_failed }) == .failed);
    }
}

test "stale responses and a different pending removal do not corrupt an operation" {
    var f = try fixture();
    defer f.decoded.deinit();
    var transaction = Transaction.init(std.testing.allocator);
    defer transaction.deinit();
    const mark = (try transaction.begin(10, f.decoded.value, &f.identity.id)).file;
    try std.testing.expect(transaction.onFile(.{ .operation_id = 11, .request_id = mark.request_id, .outcome = .ok }) == .stale);
    try std.testing.expect(transaction.onFile(.{ .operation_id = 10, .request_id = mark.request_id + 1, .outcome = .ok }) == .stale);

    var blocked = Transaction.init(std.testing.allocator);
    defer blocked.deinit();
    f.decoded.value.pendingRemoval = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try std.testing.expectError(error.Busy, blocked.begin(12, f.decoded.value, &f.identity.id));
}
