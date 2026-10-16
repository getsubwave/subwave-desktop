//! Candidate-only credential, probe, validation, and compensated vault transaction.
const std = @import("std");
const protocol = @import("station_protocol.zig");
const selection = @import("station_selection.zig");
const effects = @import("host_effects.zig");
const vault = @import("credential_vault.zig");
const identity = @import("station_identity.zig");

const Edit = enum { keep, clear, replace };
const Stage = enum { reads, health, state, listener_auth, write_basic, write_listener, rollback_listener, rollback_basic, done };

pub const ActivationCredentials = struct {
    basic: ?vault.BasicRecord,
    listener: ?vault.ListenerRecord,
    pub fn deinit(self: *ActivationCredentials) void {
        if (self.basic) |*v| v.deinit();
        if (self.listener) |*v| v.deinit();
        self.basic = null;
        self.listener = null;
    }
};

pub const Transaction = struct {
    coordinator: *selection.Coordinator,
    http: *effects.Owner,
    operation_id: u64,
    generation: u64,
    station: identity.StationIdentity,
    allow_insecure_http: bool,
    stage: Stage = .reads,
    cancelled: bool = false,
    pending_failure: ?selection.HealthFailure = null,
    basic_edit: Edit,
    listener_edit: Edit,
    replacement_basic: ?vault.BasicRecord = null,
    replacement_listener: ?vault.ListenerRecord = null,
    original_basic: ?vault.BasicRecord = null,
    original_listener: ?vault.ListenerRecord = null,
    active_basic: ?vault.BasicRecord = null,
    active_listener: ?vault.ListenerRecord = null,
    basic_read_tag: effects.VaultTag,
    listener_read_tag: effects.VaultTag,
    basic_read_done: bool = false,
    listener_read_done: bool = false,
    current_vault_tag: ?effects.VaultTag = null,
    health_tag: ?effects.RequestTag = null,
    current_http_tag: ?effects.RequestTag = null,
    changed_basic: bool = false,
    changed_listener: bool = false,
    basic_key: [vault.max_key_bytes]u8 = undefined,
    basic_key_len: u16,
    listener_key: [vault.max_key_bytes]u8 = undefined,
    listener_key_len: u16,
    authorization: [vault.max_effect_header_bytes]u8 = undefined,
    authorization_len: u16 = 0,
    listener_body: [8192]u8 = undefined,
    listener_body_len: u16 = 0,

    pub fn begin(coordinator: *selection.Coordinator, http: *effects.Owner, connect: protocol.Connect) !Transaction {
        const begun = try coordinator.begin(connect.address);
        errdefer _ = coordinator.failCandidate(begun.operation_id, .credentials_invalid) catch {};
        var result: Transaction = undefined;
        result = .{
            .coordinator = coordinator,
            .http = http,
            .operation_id = begun.operation_id,
            .generation = begun.generation,
            .station = begun.station,
            .allow_insecure_http = connect.allowInsecureHttp,
            .basic_edit = switch (connect.basic) {
                .keep => .keep,
                .clear => .clear,
                .replace => .replace,
            },
            .listener_edit = switch (connect.listenerPassword) {
                .keep => .keep,
                .clear => .clear,
                .replace => .replace,
            },
            .basic_read_tag = undefined,
            .listener_read_tag = undefined,
            .basic_key_len = 0,
            .listener_key_len = 0,
        };
        errdefer result.deinit();
        if (connect.basic == .replace) result.replacement_basic = try vault.BasicRecord.init(connect.basic.replace.username, connect.basic.replace.password);
        if (connect.listenerPassword == .replace) result.replacement_listener = try vault.ListenerRecord.init(connect.listenerPassword.replace);
        const basic_key = try vault.writeKey(.basic, &begun.station.id, &result.basic_key);
        result.basic_key_len = @intCast(basic_key.len);
        const listener_key = try vault.writeKey(.listener, &begun.station.id, &result.listener_key);
        result.listener_key_len = @intCast(listener_key.len);
        result.basic_read_tag = try http.vaultGet(result.operation_id, result.generation, result.basicKey());
        result.listener_read_tag = http.vaultGet(result.operation_id, result.generation, result.listenerKey()) catch |err| {
            http.cancelVaultOperation(result.operation_id);
            return err;
        };
        return result;
    }

    pub fn deinit(self: *Transaction) void {
        clearBasic(&self.replacement_basic);
        clearBasic(&self.original_basic);
        clearBasic(&self.active_basic);
        clearListener(&self.replacement_listener);
        clearListener(&self.original_listener);
        clearListener(&self.active_listener);
        std.crypto.secureZero(u8, &self.authorization);
        std.crypto.secureZero(u8, &self.listener_body);
        self.authorization_len = 0;
        self.listener_body_len = 0;
    }

    pub fn cancel(self: *Transaction) !?selection.Resolution {
        if (self.stage == .done) return null;
        self.cancelled = true;
        self.pending_failure = .cancelled;
        self.http.cancelOperation(self.operation_id);
        self.http.cancelVaultOperation(self.operation_id);
        if (self.stage == .reads and (!self.basic_read_done or !self.listener_read_done)) return null;
        if (self.current_vault_tag != null) return null;
        return try self.rollbackOrFail();
    }

    pub fn ownsHttp(self: *const Transaction, tag: effects.RequestTag) bool {
        return tag.operation_id == self.operation_id and tag.generation == self.generation;
    }

    pub fn ownsVault(self: *const Transaction, tag: effects.VaultTag) bool {
        return tag.operation_id == self.operation_id and tag.generation == self.generation;
    }

    pub fn onVault(self: *Transaction, completion: *const effects.VaultCompletion) !?selection.Resolution {
        if (completion.tag.operation_id != self.operation_id or completion.tag.generation != self.generation) return null;
        if (self.stage == .reads) {
            if (sameVault(completion.tag, self.basic_read_tag) and !self.basic_read_done) {
                self.basic_read_done = true;
                if (completion.cancelled and self.cancelled) {} else if (completion.outcome == .ok) {
                    self.original_basic = vault.BasicRecord.parse(completion.bytes()) catch blk: {
                        self.pending_failure = .credentials_invalid;
                        break :blk null;
                    };
                } else if (completion.outcome != .miss) self.pending_failure = .@"vault-unavailable";
            } else if (sameVault(completion.tag, self.listener_read_tag) and !self.listener_read_done) {
                self.listener_read_done = true;
                if (completion.cancelled and self.cancelled) {} else if (completion.outcome == .ok) {
                    self.original_listener = vault.ListenerRecord.init(completion.bytes()) catch blk: {
                        self.pending_failure = .credentials_invalid;
                        break :blk null;
                    };
                } else if (completion.outcome != .miss) self.pending_failure = .@"vault-unavailable";
            } else return null;
            if (!self.basic_read_done or !self.listener_read_done) return null;
            if (self.cancelled or self.pending_failure != null) return try self.rollbackOrFail();
            return try self.prepareAndProbe();
        }
        const expected = self.current_vault_tag orelse return null;
        if (!sameVault(expected, completion.tag)) return null;
        self.current_vault_tag = null;
        const succeeded = completion.outcome == .ok;
        switch (self.stage) {
            .write_basic => {
                if (succeeded) self.changed_basic = true else self.pending_failure = .vault_write_failed;
                if (self.cancelled or !succeeded) return try self.rollbackOrFail();
                return self.startListenerWriteOrActivate() catch {
                    self.pending_failure = .vault_write_failed;
                    return try self.rollbackOrFail();
                };
            },
            .write_listener => {
                if (succeeded) self.changed_listener = true else self.pending_failure = .vault_write_failed;
                if (self.cancelled or !succeeded) return try self.rollbackOrFail();
                return try self.activate();
            },
            .rollback_listener => {
                if (!succeeded) self.pending_failure = .vault_rollback_failed;
                self.changed_listener = false;
                return try self.startBasicRollbackOrFail();
            },
            .rollback_basic => {
                if (!succeeded) self.pending_failure = .vault_rollback_failed;
                self.changed_basic = false;
                return try self.finishFailure();
            },
            else => return null,
        }
    }

    pub fn onHttp(self: *Transaction, completion: *const effects.Completion) !?selection.Resolution {
        const expected = self.current_http_tag orelse return null;
        if (!sameHttp(expected, completion.tag)) return null;
        self.current_http_tag = null;
        if (completion.result == .failure) {
            self.pending_failure = httpFailure(completion.result.failure);
            return try self.rollbackOrFail();
        }
        switch (self.stage) {
            .health => {
                if (!completion.result.data.payload.health.isHealthy()) {
                    self.pending_failure = .health_failed;
                    return try self.rollbackOrFail();
                }
                const tag = self.http.request(&self.station, self.operation_id, self.generation, .state, self.auth(), null) catch {
                    self.pending_failure = .offline;
                    return try self.rollbackOrFail();
                };
                self.stage = .state;
                self.current_http_tag = tag;
                return null;
            },
            .state => {
                const listener_required = completion.result.data.payload.state.privacy.listener_auth;
                if (listener_required and self.active_listener == null) {
                    self.pending_failure = .listener_auth_required;
                    return try self.rollbackOrFail();
                }
                if (self.active_listener != null) {
                    self.buildListenerBody() catch {
                        self.pending_failure = .credentials_invalid;
                        return try self.rollbackOrFail();
                    };
                    self.current_http_tag = self.http.request(&self.station, self.operation_id, self.generation, .station_auth, self.auth(), self.listener_body[0..self.listener_body_len]) catch {
                        self.pending_failure = .offline;
                        return try self.rollbackOrFail();
                    };
                    self.stage = .listener_auth;
                    return null;
                }
                return self.startWritesOrActivate() catch {
                    self.pending_failure = .vault_write_failed;
                    return try self.rollbackOrFail();
                };
            },
            .listener_auth => {
                if (!(completion.result.data.payload.station_auth.ok orelse false)) {
                    self.pending_failure = .listener_auth_failed;
                    return try self.rollbackOrFail();
                }
                return self.startWritesOrActivate() catch {
                    self.pending_failure = .vault_write_failed;
                    return try self.rollbackOrFail();
                };
            },
            else => return null,
        }
    }

    pub fn takeActivationCredentials(self: *Transaction) ?ActivationCredentials {
        if (self.stage != .done or self.pending_failure != null) return null;
        const result: ActivationCredentials = .{ .basic = self.active_basic, .listener = self.active_listener };
        self.active_basic = null;
        self.active_listener = null;
        return result;
    }

    fn prepareAndProbe(self: *Transaction) !?selection.Resolution {
        self.active_basic = switch (self.basic_edit) {
            .keep => self.original_basic,
            .clear => null,
            .replace => self.replacement_basic,
        };
        self.active_listener = switch (self.listener_edit) {
            .keep => self.original_listener,
            .clear => null,
            .replace => self.replacement_listener,
        };
        // Keep originals and replacements as rollback sources; active copies are separately zeroed/moved.
        if (self.active_basic) |v| self.active_basic = v;
        if (self.active_listener) |v| self.active_listener = v;
        const has_credentials = self.active_basic != null or self.active_listener != null;
        if (has_credentials and std.mem.startsWith(u8, self.station.base(), "http://") and !self.allow_insecure_http) {
            self.pending_failure = .http_consent_required;
            return try self.finishFailure();
        }
        if (self.active_basic) |*record| {
            const authorization = vault.writeAuthorization(record, &self.authorization) catch {
                self.pending_failure = .credentials_invalid;
                return try self.finishFailure();
            };
            self.authorization_len = @intCast(authorization.len);
        }
        const health = self.http.request(&self.station, self.operation_id, self.generation, .health, self.auth(), null) catch {
            self.pending_failure = .offline;
            return try self.finishFailure();
        };
        self.coordinator.attachRequest(self.operation_id, health) catch {
            self.pending_failure = .health_failed;
            return try self.finishFailure();
        };
        self.health_tag = health;
        self.current_http_tag = health;
        self.stage = .health;
        return null;
    }

    fn startWritesOrActivate(self: *Transaction) !?selection.Resolution {
        if (self.basic_edit != .keep) {
            self.stage = .write_basic;
            self.current_vault_tag = if (self.basic_edit == .clear) try self.http.vaultDelete(self.operation_id, self.generation, self.basicKey()) else blk: {
                var serialized: [vault.max_secret_bytes]u8 = undefined;
                defer std.crypto.secureZero(u8, &serialized);
                const bytes = try vault.writeBasicRecord(&self.replacement_basic.?, &serialized);
                break :blk try self.http.vaultSet(self.operation_id, self.generation, self.basicKey(), bytes);
            };
            return null;
        }
        return try self.startListenerWriteOrActivate();
    }
    fn startListenerWriteOrActivate(self: *Transaction) !?selection.Resolution {
        if (self.listener_edit != .keep) {
            self.stage = .write_listener;
            self.current_vault_tag = if (self.listener_edit == .clear) try self.http.vaultDelete(self.operation_id, self.generation, self.listenerKey()) else try self.http.vaultSet(self.operation_id, self.generation, self.listenerKey(), self.replacement_listener.?.password());
            return null;
        }
        return try self.activate();
    }
    fn activate(self: *Transaction) !?selection.Resolution {
        self.stage = .done;
        return self.coordinator.resolve(self.health_tag.?, .healthy);
    }
    fn rollbackOrFail(self: *Transaction) !?selection.Resolution {
        if (self.changed_listener) {
            self.stage = .rollback_listener;
            self.current_vault_tag = self.restoreListener() catch {
                self.pending_failure = .vault_rollback_failed;
                self.changed_listener = false;
                return try self.startBasicRollbackOrFail();
            };
            return null;
        }
        return try self.startBasicRollbackOrFail();
    }
    fn startBasicRollbackOrFail(self: *Transaction) !?selection.Resolution {
        if (self.changed_basic) {
            self.stage = .rollback_basic;
            self.current_vault_tag = self.restoreBasic() catch {
                self.pending_failure = .vault_rollback_failed;
                self.changed_basic = false;
                return try self.finishFailure();
            };
            return null;
        }
        return try self.finishFailure();
    }
    fn restoreBasic(self: *Transaction) !effects.VaultTag {
        if (self.original_basic) |*record| {
            var bytes: [vault.max_secret_bytes]u8 = undefined;
            defer std.crypto.secureZero(u8, &bytes);
            const value = try vault.writeBasicRecord(record, &bytes);
            return self.http.vaultSet(self.operation_id, self.generation, self.basicKey(), value);
        }
        return self.http.vaultDelete(self.operation_id, self.generation, self.basicKey());
    }
    fn restoreListener(self: *Transaction) !effects.VaultTag {
        if (self.original_listener) |*record| return self.http.vaultSet(self.operation_id, self.generation, self.listenerKey(), record.password());
        return self.http.vaultDelete(self.operation_id, self.generation, self.listenerKey());
    }
    fn finishFailure(self: *Transaction) !?selection.Resolution {
        self.stage = .done;
        return try self.coordinator.failCandidate(self.operation_id, self.pending_failure orelse .health_failed);
    }
    fn auth(self: *const Transaction) @import("station_client.zig").Auth {
        return .{ .authorization = if (self.authorization_len > 0) self.authorization[0..self.authorization_len] else null, .allow_insecure_http = self.allow_insecure_http };
    }
    fn basicKey(self: *const Transaction) []const u8 {
        return self.basic_key[0..self.basic_key_len];
    }
    fn listenerKey(self: *const Transaction) []const u8 {
        return self.listener_key[0..self.listener_key_len];
    }
    fn buildListenerBody(self: *Transaction) !void {
        var writer = std.Io.Writer.fixed(&self.listener_body);
        writer.writeAll("{\"password\":") catch return error.ListenerBodyTooLarge;
        try writeJson(&writer, self.active_listener.?.password());
        writer.writeByte('}') catch return error.ListenerBodyTooLarge;
        self.listener_body_len = @intCast(writer.buffered().len);
    }
};

fn sameVault(a: effects.VaultTag, b: effects.VaultTag) bool {
    return a.operation_id == b.operation_id and a.generation == b.generation and a.request_id == b.request_id;
}
fn sameHttp(a: effects.RequestTag, b: effects.RequestTag) bool {
    return a.operation_id == b.operation_id and a.generation == b.generation and a.request_id == b.request_id and a.kind == b.kind;
}
fn clearBasic(value: *?vault.BasicRecord) void {
    if (value.*) |*v| v.deinit();
    value.* = null;
}
fn clearListener(value: *?vault.ListenerRecord) void {
    if (value.*) |*v| v.deinit();
    value.* = null;
}
fn httpFailure(value: effects.Failure) selection.HealthFailure {
    return switch (value) {
        .auth_required => .@"auth-required",
        .forbidden => .forbidden,
        .rate_limited => .rate_limited,
        .redirect_denied => .redirect_denied,
        else => .offline,
    };
}
fn writeJson(writer: *std.Io.Writer, value: []const u8) !void {
    writer.writeByte('"') catch return error.ListenerBodyTooLarge;
    for (value) |byte| switch (byte) {
        '"' => writer.writeAll("\\\"") catch return error.ListenerBodyTooLarge,
        '\\' => writer.writeAll("\\\\") catch return error.ListenerBodyTooLarge,
        0...0x1f => writer.print("\\u00{X:0>2}", .{byte}) catch return error.ListenerBodyTooLarge,
        else => writer.writeByte(byte) catch return error.ListenerBodyTooLarge,
    };
    writer.writeByte('"') catch return error.ListenerBodyTooLarge;
}

fn feedVault(owner: *effects.Owner, tag: effects.VaultTag, operation: effects.VaultOperation, outcome: @import("native_sdk").EffectCredentialsOutcome) !effects.VaultCompletion {
    try owner.effects.feedCredentialsResult(tag.request_id, operation, outcome, 0, .{0} ** 32);
    var boundary = owner.boundary();
    while (owner.next(&boundary)) |value| {
        var completion = value;
        completion.deinit();
    }
    return owner.nextVault() orelse error.TestExpectedVault;
}
fn feedHttp(owner: *effects.Owner, tag: effects.RequestTag, status: u16, body: []const u8) !effects.Completion {
    try owner.effects.feedResponse(tag.request_id, status, body);
    var boundary = owner.boundary();
    return owner.next(&boundary) orelse error.TestExpectedHttp;
}
fn publicConnect(address: []const u8) protocol.Connect {
    return .{ .address = address, .basic = .keep, .listenerPassword = .keep, .allowInsecureHttp = false };
}

test "known vault read failure is not a miss and preserves active station" {
    var coordinator: selection.Coordinator = .{};
    const existing = try coordinator.begin("active.example");
    const existing_tag: effects.RequestTag = .{ .operation_id = existing.operation_id, .generation = existing.generation, .request_id = 1, .kind = .health };
    try coordinator.attachRequest(existing.operation_id, existing_tag);
    _ = coordinator.resolve(existing_tag, .healthy);
    var platform = @import("native_sdk").platform.NullPlatform.init(.{});
    defer platform.deinit();
    var binding = platform.platform();
    var owner = try effects.Owner.init(std.testing.allocator);
    defer owner.deinit();
    owner.effects.executor = .fake;
    owner.effects.bindCredentialsStore(.{ .services = &binding.services, .service = "dev.subwave.candidate-test", .permitted = true });
    var transaction = try Transaction.begin(&coordinator, &owner, publicConnect("candidate.example"));
    defer transaction.deinit();
    var basic = try feedVault(&owner, transaction.basic_read_tag, .get, .locked);
    defer basic.deinit();
    try std.testing.expect((try transaction.onVault(&basic)) == null);
    var listener = try feedVault(&owner, transaction.listener_read_tag, .get, .miss);
    defer listener.deinit();
    const resolution = (try transaction.onVault(&listener)).?.failed;
    try std.testing.expectEqualStrings("vault-unavailable", resolution.errorCode.?);
    try std.testing.expectEqualStrings("https://active.example", coordinator.active_station.?.base());
}

test "state privacy requires a listener credential before activation" {
    var coordinator: selection.Coordinator = .{};
    var platform = @import("native_sdk").platform.NullPlatform.init(.{});
    defer platform.deinit();
    var binding = platform.platform();
    var owner = try effects.Owner.init(std.testing.allocator);
    defer owner.deinit();
    owner.effects.executor = .fake;
    owner.effects.bindCredentialsStore(.{ .services = &binding.services, .service = "dev.subwave.candidate-test", .permitted = true });
    var transaction = try Transaction.begin(&coordinator, &owner, publicConnect("candidate.example"));
    defer transaction.deinit();
    var basic = try feedVault(&owner, transaction.basic_read_tag, .get, .miss);
    defer basic.deinit();
    _ = try transaction.onVault(&basic);
    var listener = try feedVault(&owner, transaction.listener_read_tag, .get, .miss);
    defer listener.deinit();
    _ = try transaction.onVault(&listener);
    var health = try feedHttp(&owner, transaction.current_http_tag.?, 200, "{\"status\":\"on-air\"}");
    defer health.deinit();
    _ = try transaction.onHttp(&health);
    var state = try feedHttp(&owner, transaction.current_http_tag.?, 200, "{\"privacy\":{\"listenerAuth\":true}}");
    defer state.deinit();
    const resolution = (try transaction.onHttp(&state)).?.failed;
    try std.testing.expectEqualStrings("listener_auth_required", resolution.errorCode.?);
    try std.testing.expect(coordinator.active_station == null);
}

test "supplied listener credential is validated when state says it is optional" {
    var coordinator: selection.Coordinator = .{};
    const existing = try coordinator.begin("active.example");
    const existing_tag: effects.RequestTag = .{ .operation_id = existing.operation_id, .generation = existing.generation, .request_id = 1, .kind = .health };
    try coordinator.attachRequest(existing.operation_id, existing_tag);
    _ = coordinator.resolve(existing_tag, .healthy);
    var platform = @import("native_sdk").platform.NullPlatform.init(.{});
    defer platform.deinit();
    var binding = platform.platform();
    var owner = try effects.Owner.init(std.testing.allocator);
    defer owner.deinit();
    owner.effects.executor = .fake;
    owner.effects.bindCredentialsStore(.{ .services = &binding.services, .service = "dev.subwave.candidate-test", .permitted = true });
    var transaction = try Transaction.begin(&coordinator, &owner, .{ .address = "candidate.example", .basic = .keep, .listenerPassword = .{ .replace = "wrong" }, .allowInsecureHttp = false });
    defer transaction.deinit();
    var basic = try feedVault(&owner, transaction.basic_read_tag, .get, .miss);
    defer basic.deinit();
    _ = try transaction.onVault(&basic);
    var listener = try feedVault(&owner, transaction.listener_read_tag, .get, .miss);
    defer listener.deinit();
    _ = try transaction.onVault(&listener);
    var health = try feedHttp(&owner, transaction.current_http_tag.?, 200, "{\"status\":\"on-air\"}");
    defer health.deinit();
    _ = try transaction.onHttp(&health);
    var state = try feedHttp(&owner, transaction.current_http_tag.?, 200, "{\"privacy\":{\"listenerAuth\":false}}");
    defer state.deinit();
    try std.testing.expect((try transaction.onHttp(&state)) == null);
    try std.testing.expectEqual(Stage.listener_auth, transaction.stage);
    try std.testing.expect(transaction.current_vault_tag == null);
    var auth = try feedHttp(&owner, transaction.current_http_tag.?, 200, "{\"ok\":false}");
    defer auth.deinit();
    const resolution = (try transaction.onHttp(&auth)).?.failed;
    try std.testing.expectEqualStrings("listener_auth_failed", resolution.errorCode.?);
    try std.testing.expectEqualStrings("https://active.example", coordinator.active_station.?.base());
    try std.testing.expect(transaction.current_vault_tag == null);
}

test "cancellation after a successful write waits for compensation" {
    var coordinator: selection.Coordinator = .{};
    var platform = @import("native_sdk").platform.NullPlatform.init(.{});
    defer platform.deinit();
    var binding = platform.platform();
    var owner = try effects.Owner.init(std.testing.allocator);
    defer owner.deinit();
    owner.effects.executor = .fake;
    owner.effects.bindCredentialsStore(.{ .services = &binding.services, .service = "dev.subwave.candidate-test", .permitted = true });
    var transaction = try Transaction.begin(&coordinator, &owner, .{ .address = "candidate.example", .basic = .{ .replace = .{ .username = "user", .password = "pass" } }, .listenerPassword = .keep, .allowInsecureHttp = false });
    defer transaction.deinit();
    var basic = try feedVault(&owner, transaction.basic_read_tag, .get, .miss);
    defer basic.deinit();
    _ = try transaction.onVault(&basic);
    var listener = try feedVault(&owner, transaction.listener_read_tag, .get, .miss);
    defer listener.deinit();
    _ = try transaction.onVault(&listener);
    var health = try feedHttp(&owner, transaction.current_http_tag.?, 200, "{\"status\":\"on-air\"}");
    defer health.deinit();
    _ = try transaction.onHttp(&health);
    var state = try feedHttp(&owner, transaction.current_http_tag.?, 200, "{\"privacy\":{\"listenerAuth\":false}}");
    defer state.deinit();
    _ = try transaction.onHttp(&state);
    const write_tag = transaction.current_vault_tag.?;
    try std.testing.expect((try transaction.cancel()) == null);
    try std.testing.expectError(error.Busy, coordinator.begin("other.example"));
    var written = try feedVault(&owner, write_tag, .set, .ok);
    defer written.deinit();
    try std.testing.expect((try transaction.onVault(&written)) == null);
    try std.testing.expectEqual(Stage.rollback_basic, transaction.stage);
    var rollback = try feedVault(&owner, transaction.current_vault_tag.?, .delete, .ok);
    defer rollback.deinit();
    const resolution = (try transaction.onVault(&rollback)).?.failed;
    try std.testing.expectEqualStrings("cancelled", resolution.errorCode.?);
    try std.testing.expect(coordinator.active_station == null);
}
