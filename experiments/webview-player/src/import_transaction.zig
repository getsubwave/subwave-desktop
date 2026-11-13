//! Pure, serialized legacy-import transaction coordinator.
const std = @import("std");
const protocol = @import("station_protocol.zig");
const preferences = @import("preferences.zig");
const settings_import = @import("settings_import.zig");
const vault = @import("credential_vault.zig");

pub const FileKind = enum { read_legacy, backup, save };
pub const FileOutcome = enum { ok, miss, failed, cancelled };
pub const FileResult = struct { operation_id: u64, kind: FileKind, outcome: FileOutcome, bytes: []const u8 = &.{} };
pub const VaultOperation = enum { get, set };
pub const VaultResult = struct { operation_id: u64, request_id: u64, operation: VaultOperation, outcome: vault.Outcome, bytes: []const u8 = &.{} };

pub const FileCommand = struct {
    operation_id: u64,
    kind: FileKind,
    bytes_storage: [preferences.max_output_bytes]u8 = undefined,
    bytes_len: u16 = 0,
    pub fn bytes(self: *const FileCommand) []const u8 {
        return self.bytes_storage[0..self.bytes_len];
    }
    pub fn deinit(self: *FileCommand) void {
        std.crypto.secureZero(u8, &self.bytes_storage);
        self.* = undefined;
    }
};
pub const VaultCommand = struct {
    operation_id: u64,
    request_id: u64,
    operation: VaultOperation,
    key_storage: [vault.max_key_bytes]u8 = undefined,
    key_len: u16,
    bytes_storage: [vault.max_secret_bytes]u8 = undefined,
    bytes_len: u16 = 0,
    pub fn key(self: *const VaultCommand) []const u8 {
        return self.key_storage[0..self.key_len];
    }
    pub fn bytes(self: *const VaultCommand) []const u8 {
        return self.bytes_storage[0..self.bytes_len];
    }
    pub fn deinit(self: *VaultCommand) void {
        std.crypto.secureZero(u8, &self.bytes_storage);
        self.* = undefined;
    }
};
pub const Failure = enum { no_import, invalid_source, file_failed, vault_locked, vault_denied, vault_io_failed, vault_rejected, vault_over_bound, verify_failed, cancelled };
pub const Step = union(enum) { file: FileCommand, vault: VaultCommand, succeeded, failed: Failure, stale };

const Phase = enum { idle, reading, backing_up, vault_get, vault_set, vault_verify, saving, succeeded, failed };

pub const Transaction = struct {
    allocator: std.mem.Allocator,
    phase: Phase = .idle,
    operation_id: u64 = 0,
    candidate: ?settings_import.Candidate = null,
    source_storage: [settings_import.max_source_bytes]u8 = undefined,
    source_len: u16 = 0,
    station_index: usize = 0,
    kind: vault.Kind = .basic,
    next_request_id: u64 = 1,
    expected_request_id: u64 = 0,
    expected_storage: [vault.max_secret_bytes]u8 = undefined,
    expected_len: u16 = 0,

    pub fn init(allocator: std.mem.Allocator) Transaction {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Transaction) void {
        if (self.candidate) |*candidate| candidate.deinit();
        std.crypto.secureZero(u8, &self.source_storage);
        std.crypto.secureZero(u8, &self.expected_storage);
        self.* = undefined;
    }

    pub fn begin(self: *Transaction, operation_id: u64) !Step {
        if (self.phase != .idle) return error.Busy;
        if (operation_id == 0 or operation_id > protocol.max_operation_id) return error.InvalidOperation;
        self.operation_id = operation_id;
        self.phase = .reading;
        return .{ .file = fileCommand(operation_id, .read_legacy, &.{}) };
    }

    pub fn onFile(self: *Transaction, result: FileResult) Step {
        if (result.operation_id != self.operation_id) return .stale;
        return switch (self.phase) {
            .reading => self.onRead(result),
            .backing_up => if (result.kind != .backup) .stale else switch (result.outcome) {
                .ok => self.beginVault(),
                .cancelled => self.fail(.cancelled),
                else => self.fail(.file_failed),
            },
            .saving => if (result.kind != .save) .stale else switch (result.outcome) {
                .ok => blk: {
                    self.phase = .succeeded;
                    break :blk .succeeded;
                },
                .cancelled => self.fail(.cancelled),
                else => self.fail(.file_failed),
            },
            else => .stale,
        };
    }

    pub fn onVault(self: *Transaction, result: VaultResult) Step {
        if (result.operation_id != self.operation_id or result.request_id != self.expected_request_id) return .stale;
        return switch (self.phase) {
            .vault_get => if (result.operation != .get) .stale else switch (result.outcome) {
                .ok => self.advanceVault(), // Existing secure data always wins.
                .miss => self.issueSet(),
                else => self.fail(vaultFailure(result.outcome)),
            },
            .vault_set => if (result.operation != .set) .stale else switch (result.outcome) {
                .ok => self.issueVerify(),
                else => self.fail(vaultFailure(result.outcome)),
            },
            .vault_verify => if (result.operation != .get) .stale else switch (result.outcome) {
                .ok => if (std.mem.eql(u8, result.bytes, self.expected_storage[0..self.expected_len])) self.advanceVault() else self.fail(.verify_failed),
                else => self.fail(vaultFailure(result.outcome)),
            },
            else => .stale,
        };
    }

    pub fn takeSucceeded(self: *Transaction) !settings_import.Candidate {
        if (self.phase != .succeeded) return error.NotSucceeded;
        const candidate = self.candidate orelse return error.NotSucceeded;
        self.candidate = null;
        std.crypto.secureZero(u8, &self.source_storage);
        std.crypto.secureZero(u8, &self.expected_storage);
        self.source_len = 0;
        self.expected_len = 0;
        self.phase = .idle;
        self.operation_id = 0;
        return candidate;
    }

    fn onRead(self: *Transaction, result: FileResult) Step {
        if (result.kind != .read_legacy) return .stale;
        switch (result.outcome) {
            .miss => return self.fail(.no_import),
            .cancelled => return self.fail(.cancelled),
            .failed => return self.fail(.file_failed),
            .ok => {},
        }
        if (result.bytes.len > self.source_storage.len) return self.fail(.invalid_source);
        @memcpy(self.source_storage[0..result.bytes.len], result.bytes);
        self.source_len = @intCast(result.bytes.len);
        self.candidate = settings_import.parse(self.allocator, result.bytes) catch return self.fail(.invalid_source);
        self.phase = .backing_up;
        return .{ .file = fileCommand(self.operation_id, .backup, self.source_storage[0..self.source_len]) };
    }

    fn beginVault(self: *Transaction) Step {
        self.station_index = 0;
        self.kind = .basic;
        return self.seekCredential();
    }

    fn seekCredential(self: *Transaction) Step {
        while (self.station_index < preferences.max_stations) {
            const credential = &self.candidate.?.credentials[self.station_index];
            if ((self.kind == .basic and credential.basic != null) or (self.kind == .listener and credential.listener != null)) return self.issueGet();
            self.nextKind();
        }
        return self.issueSave();
    }

    fn issueGet(self: *Transaction) Step {
        self.phase = .vault_get;
        return .{ .vault = self.vaultCommand(.get, &.{}) catch return self.fail(.vault_over_bound) };
    }
    fn issueSet(self: *Transaction) Step {
        self.phase = .vault_set;
        var command = self.vaultCommand(.set, if (self.kind == .listener) self.candidate.?.credentials[self.station_index].listener.?.password() else &.{}) catch return self.fail(.vault_over_bound);
        @memcpy(self.expected_storage[0..command.bytes_len], command.bytes());
        self.expected_len = command.bytes_len;
        return .{ .vault = command };
    }
    fn issueVerify(self: *Transaction) Step {
        self.phase = .vault_verify;
        return .{ .vault = self.vaultCommand(.get, &.{}) catch return self.fail(.vault_over_bound) };
    }
    fn advanceVault(self: *Transaction) Step {
        std.crypto.secureZero(u8, self.expected_storage[0..self.expected_len]);
        self.expected_len = 0;
        self.nextKind();
        return self.seekCredential();
    }
    fn nextKind(self: *Transaction) void {
        if (self.kind == .basic) self.kind = .listener else {
            self.kind = .basic;
            self.station_index += 1;
        }
    }

    fn vaultCommand(self: *Transaction, operation: VaultOperation, bytes: []const u8) !VaultCommand {
        if (self.next_request_id == 0 or self.next_request_id > protocol.max_operation_id) return error.IdentityExhausted;
        const station = self.candidate.?.preferences.stations[self.station_index];
        var command: VaultCommand = .{ .operation_id = self.operation_id, .request_id = self.next_request_id, .operation = operation, .key_len = 0 };
        const key = try vault.writeKey(self.kind, station.id, &command.key_storage);
        command.key_len = @intCast(key.len);
        if (operation == .set) {
            const value = if (self.kind == .basic) try vault.writeBasicRecord(&self.candidate.?.credentials[self.station_index].basic.?, &command.bytes_storage) else blk: {
                if (bytes.len > command.bytes_storage.len) return error.OverBound;
                @memcpy(command.bytes_storage[0..bytes.len], bytes);
                break :blk command.bytes_storage[0..bytes.len];
            };
            command.bytes_len = @intCast(value.len);
        }
        self.expected_request_id = self.next_request_id;
        self.next_request_id += 1;
        return command;
    }

    fn issueSave(self: *Transaction) Step {
        self.clearCredentialRecords();
        const candidate = &self.candidate.?;
        const digest = candidate.arena.allocator().alloc(u8, 64) catch return self.fail(.file_failed);
        _ = std.fmt.bufPrint(digest, "{x}", .{candidate.source_digest}) catch return self.fail(.file_failed);
        candidate.preferences.legacyImport = .{ .completed = true, .sourceDigest = digest };
        var command: FileCommand = .{ .operation_id = self.operation_id, .kind = .save };
        const encoded = preferences.encode(candidate.preferences, &command.bytes_storage) catch return self.fail(.file_failed);
        command.bytes_len = @intCast(encoded.len);
        self.phase = .saving;
        return .{ .file = command };
    }

    fn clearCredentialRecords(self: *Transaction) void {
        for (&self.candidate.?.credentials) |*credential| {
            if (credential.basic) |*record| record.deinit();
            if (credential.listener) |*record| record.deinit();
            credential.* = .{};
        }
    }

    fn fail(self: *Transaction, failure: Failure) Step {
        if (self.candidate) |*candidate| candidate.deinit();
        self.candidate = null;
        std.crypto.secureZero(u8, &self.source_storage);
        std.crypto.secureZero(u8, &self.expected_storage);
        self.source_len = 0;
        self.phase = .failed;
        return .{ .failed = failure };
    }
};

fn fileCommand(operation_id: u64, kind: FileKind, bytes: []const u8) FileCommand {
    var command: FileCommand = .{ .operation_id = operation_id, .kind = kind };
    @memcpy(command.bytes_storage[0..bytes.len], bytes);
    command.bytes_len = @intCast(bytes.len);
    return command;
}
fn vaultFailure(outcome: vault.Outcome) Failure {
    return switch (outcome) {
        .locked => .vault_locked,
        .denied => .vault_denied,
        .io_failed => .vault_io_failed,
        .over_bound => .vault_over_bound,
        .rejected, .miss => .vault_rejected,
        .ok => unreachable,
    };
}

fn expectFile(step: Step, kind: FileKind) FileCommand {
    const command = step.file;
    std.debug.assert(command.kind == kind);
    return command;
}
fn expectVault(step: Step, operation: VaultOperation) VaultCommand {
    const command = step.vault;
    std.debug.assert(command.operation == operation);
    return command;
}

test "existing secure values win and successful import marks preferences only after save" {
    var tx = Transaction.init(std.testing.allocator);
    defer tx.deinit();
    _ = expectFile(try tx.begin(41), .read_legacy);
    const source = "{\"station\":\"https://legacy:password@radio.example\",\"stationPassword\":\"listener\"}";
    _ = expectFile(tx.onFile(.{ .operation_id = 41, .kind = .read_legacy, .outcome = .ok, .bytes = source }), .backup);
    var get_basic = expectVault(tx.onFile(.{ .operation_id = 41, .kind = .backup, .outcome = .ok }), .get);
    defer get_basic.deinit();
    var get_listener = expectVault(tx.onVault(.{ .operation_id = 41, .request_id = get_basic.request_id, .operation = .get, .outcome = .ok, .bytes = "secure-basic" }), .get);
    defer get_listener.deinit();
    const save = expectFile(tx.onVault(.{ .operation_id = 41, .request_id = get_listener.request_id, .operation = .get, .outcome = .ok, .bytes = "secure-listener" }), .save);
    try std.testing.expect(std.mem.indexOf(u8, save.bytes(), "password") == null);
    try std.testing.expect(tx.onFile(.{ .operation_id = 41, .kind = .save, .outcome = .ok }) == .succeeded);
    var candidate = try tx.takeSucceeded();
    defer candidate.deinit();
    try std.testing.expect(candidate.preferences.legacyImport.completed);
    try std.testing.expect(candidate.credentials[0].basic == null and candidate.credentials[0].listener == null);
}

test "miss writes and verifies exact legacy bytes before preferences save" {
    var tx = Transaction.init(std.testing.allocator);
    defer tx.deinit();
    _ = try tx.begin(7);
    const source = "{\"station\":\"https://u:p@radio.example\"}";
    _ = tx.onFile(.{ .operation_id = 7, .kind = .read_legacy, .outcome = .ok, .bytes = source });
    var get = expectVault(tx.onFile(.{ .operation_id = 7, .kind = .backup, .outcome = .ok }), .get);
    defer get.deinit();
    var set = expectVault(tx.onVault(.{ .operation_id = 7, .request_id = get.request_id, .operation = .get, .outcome = .miss }), .set);
    defer set.deinit();
    var verify = expectVault(tx.onVault(.{ .operation_id = 7, .request_id = set.request_id, .operation = .set, .outcome = .ok }), .get);
    defer verify.deinit();
    try std.testing.expect(tx.onVault(.{ .operation_id = 7, .request_id = verify.request_id, .operation = .get, .outcome = .ok, .bytes = "wrong" }) == .failed);
}

test "vault lock and every file boundary fail without a completed candidate" {
    var tx = Transaction.init(std.testing.allocator);
    defer tx.deinit();
    _ = try tx.begin(1);
    try std.testing.expect(tx.onFile(.{ .operation_id = 1, .kind = .read_legacy, .outcome = .miss }) == .failed);
    var locked = Transaction.init(std.testing.allocator);
    defer locked.deinit();
    _ = try locked.begin(2);
    _ = locked.onFile(.{ .operation_id = 2, .kind = .read_legacy, .outcome = .ok, .bytes = "{\"station\":\"https://u:p@radio.example\"}" });
    const get = expectVault(locked.onFile(.{ .operation_id = 2, .kind = .backup, .outcome = .ok }), .get);
    try std.testing.expectEqual(Failure.vault_locked, locked.onVault(.{ .operation_id = 2, .request_id = get.request_id, .operation = .get, .outcome = .locked }).failed);
}

test "retry after a partial legacy write observes secure ok and never rewrites it" {
    var tx = Transaction.init(std.testing.allocator);
    defer tx.deinit();
    _ = try tx.begin(9);
    _ = tx.onFile(.{ .operation_id = 9, .kind = .read_legacy, .outcome = .ok, .bytes = "{\"station\":\"https://u:p@radio.example\"}" });
    var get = expectVault(tx.onFile(.{ .operation_id = 9, .kind = .backup, .outcome = .ok }), .get);
    defer get.deinit();
    const next = tx.onVault(.{ .operation_id = 9, .request_id = get.request_id, .operation = .get, .outcome = .ok, .bytes = "already-written" });
    try std.testing.expect(next == .file and next.file.kind == .save);
}

test "legacy miss set and exact verification reach sanitized save" {
    var tx = Transaction.init(std.testing.allocator);
    defer tx.deinit();
    _ = try tx.begin(12);
    const source = "{\"station\":\"https://u:p@radio.example\"}";
    _ = tx.onFile(.{ .operation_id = 12, .kind = .read_legacy, .outcome = .ok, .bytes = source });
    var get = expectVault(tx.onFile(.{ .operation_id = 12, .kind = .backup, .outcome = .ok }), .get);
    defer get.deinit();
    var set = expectVault(tx.onVault(.{ .operation_id = 12, .request_id = get.request_id, .operation = .get, .outcome = .miss }), .set);
    defer set.deinit();
    var verify = expectVault(tx.onVault(.{ .operation_id = 12, .request_id = set.request_id, .operation = .set, .outcome = .ok }), .get);
    defer verify.deinit();
    const save = expectFile(tx.onVault(.{ .operation_id = 12, .request_id = verify.request_id, .operation = .get, .outcome = .ok, .bytes = set.bytes() }), .save);
    try std.testing.expect(std.mem.indexOf(u8, save.bytes(), "\"completed\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, save.bytes(), "password") == null);
}

test "backup set and final save failures never succeed" {
    const source = "{\"station\":\"https://u:p@radio.example\"}";
    var backup_failure = Transaction.init(std.testing.allocator);
    defer backup_failure.deinit();
    _ = try backup_failure.begin(21);
    _ = backup_failure.onFile(.{ .operation_id = 21, .kind = .read_legacy, .outcome = .ok, .bytes = source });
    try std.testing.expectEqual(Failure.file_failed, backup_failure.onFile(.{ .operation_id = 21, .kind = .backup, .outcome = .failed }).failed);

    var set_failure = Transaction.init(std.testing.allocator);
    defer set_failure.deinit();
    _ = try set_failure.begin(22);
    _ = set_failure.onFile(.{ .operation_id = 22, .kind = .read_legacy, .outcome = .ok, .bytes = source });
    const get = expectVault(set_failure.onFile(.{ .operation_id = 22, .kind = .backup, .outcome = .ok }), .get);
    const set = expectVault(set_failure.onVault(.{ .operation_id = 22, .request_id = get.request_id, .operation = .get, .outcome = .miss }), .set);
    try std.testing.expectEqual(Failure.vault_io_failed, set_failure.onVault(.{ .operation_id = 22, .request_id = set.request_id, .operation = .set, .outcome = .io_failed }).failed);

    var save_failure = Transaction.init(std.testing.allocator);
    defer save_failure.deinit();
    _ = try save_failure.begin(23);
    _ = save_failure.onFile(.{ .operation_id = 23, .kind = .read_legacy, .outcome = .ok, .bytes = source });
    const secure = expectVault(save_failure.onFile(.{ .operation_id = 23, .kind = .backup, .outcome = .ok }), .get);
    _ = expectFile(save_failure.onVault(.{ .operation_id = 23, .request_id = secure.request_id, .operation = .get, .outcome = .ok }), .save);
    try std.testing.expectEqual(Failure.file_failed, save_failure.onFile(.{ .operation_id = 23, .kind = .save, .outcome = .failed }).failed);
}

test "late mismatched file and vault results are stale without aborting active import" {
    var tx = Transaction.init(std.testing.allocator);
    defer tx.deinit();
    _ = try tx.begin(30);
    try std.testing.expect(tx.onFile(.{ .operation_id = 29, .kind = .read_legacy, .outcome = .failed }) == .stale);
    try std.testing.expect(tx.onFile(.{ .operation_id = 30, .kind = .backup, .outcome = .failed }) == .stale);
    _ = tx.onFile(.{ .operation_id = 30, .kind = .read_legacy, .outcome = .ok, .bytes = "{\"station\":\"https://u:p@radio.example\"}" });
    const get = expectVault(tx.onFile(.{ .operation_id = 30, .kind = .backup, .outcome = .ok }), .get);
    try std.testing.expect(tx.onVault(.{ .operation_id = 30, .request_id = get.request_id + 1, .operation = .get, .outcome = .locked }) == .stale);
    try std.testing.expect(tx.onVault(.{ .operation_id = 30, .request_id = get.request_id, .operation = .set, .outcome = .io_failed }) == .stale);
    try std.testing.expect(tx.onVault(.{ .operation_id = 30, .request_id = get.request_id, .operation = .get, .outcome = .ok }) == .file);
}
