//! Protocol 2's closed, bounded native bridge boundary.
const std = @import("std");
const identity_mod = @import("station_identity.zig");

pub const protocol_version: u8 = 2;
pub const max_snapshot_bytes: usize = 12 * 1024;
pub const max_canonical_base_bytes: usize = 256;
pub const max_station_id_bytes: usize = 64;
pub const max_name_bytes: usize = 64;
pub const max_theme_override_bytes: usize = 64;
pub const max_track_field_bytes: usize = 128;
pub const max_recents: usize = 8;
pub const max_vault_secret_bytes: usize = 2560;
pub const max_operation_id: u64 = 9_007_199_254_740_991;
const max_input_bytes: usize = 8 * 1024;

pub const CredentialEdit = union(enum) {
    keep,
    clear,
    replace: struct { username: []const u8, password: []const u8 },
};
pub const ListenerPasswordEdit = union(enum) { keep, clear, replace: []const u8 };
pub const Connect = struct { address: []const u8, basic: CredentialEdit, listenerPassword: ListenerPasswordEdit, allowInsecureHttp: bool };
pub const Connection = enum { none, checking, ready, offline, @"auth-required", @"vault-unavailable", @"error" };
pub const OperationState = enum { pending, succeeded, failed };
pub const OperationStatus = struct {
    operationId: u64,
    status: OperationState,
    errorCode: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), json: anytype) !void {
        try json.beginObject();
        try json.objectField("operationId");
        try json.write(self.operationId);
        try json.objectField("status");
        try json.write(self.status);
        if (self.errorCode) |code| {
            try json.objectField("errorCode");
            try json.write(code);
        }
        try json.endObject();
    }
};
pub const PreferenceUpdate = union(enum) {
    themeOverride: []const u8,
    discordClientId: []const u8,
    discordEnabled: bool,
    notifyTrack: bool,
};
pub const StreamFormat = enum { mp3, aac, opus, flac };
pub const PlaybackCommand = union(enum) { play, pause, stop, volume: f64, mute: bool, format: StreamFormat };
pub const Playback = enum { stopped, loading, playing, paused, @"error" };
pub const Intent = enum { stopped, playing, paused };
pub const Station = struct { id: []const u8, base: []const u8, name: []const u8 };
pub const Track = struct { id: []const u8, title: []const u8, artist: []const u8, album: []const u8 };
pub const Retry = struct { attempt: u32, dueInMs: u64 };
pub const Operations = struct { station: ?OperationStatus = null, persistence: ?OperationStatus = null };
pub const Preferences = struct { themeOverride: []const u8 = "", discordEnabled: bool = false, discordClientId: []const u8 = "", notifyTrack: bool = false };
pub const SnapshotError = struct { code: []const u8, retryable: bool };
pub const StationSnapshot = struct {
    protocol: u8 = protocol_version,
    revision: u64,
    generation: u64,
    playback: Playback,
    intent: Intent,
    buffering: bool,
    volume: f64,
    muted: bool,
    station: ?Station,
    connection: Connection,
    retry: ?Retry,
    track: ?Track,
    format: StreamFormat,
    operations: Operations = .{},
    recents: []const Station = &.{},
    preferences: Preferences = .{},
    @"error": ?SnapshotError = null,
};
pub const AcceptedError = enum { invalid_request, busy, unsupported };
pub const Accepted = struct { ok: bool, operationId: ?u64 = null, @"error": ?AcceptedError = null };
pub const OperationResult = struct { operationId: u64, status: enum { succeeded, failed }, errorCode: ?[]const u8 = null };

pub const Command = union(enum) {
    snapshot,
    stationConnect: Connect,
    stationCancel: u64,
    stationForget: []const u8,
    stationDisconnect,
    playbackCommand: PlaybackCommand,
    preferencesUpdate: PreferenceUpdate,
    preferencesImportLegacy,
};

pub const Parsed = struct {
    json: std.json.Parsed(std.json.Value),
    command: Command,
    parent_allocator: std.mem.Allocator,
    wiping_allocator: *WipingAllocator,
    pub fn deinit(self: *Parsed) void {
        self.json.deinit();
        self.parent_allocator.destroy(self.wiping_allocator);
        self.* = undefined;
    }
};

const WipingAllocator = struct {
    child: std.mem.Allocator,

    fn allocator(self: *WipingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *WipingAllocator = @ptrCast(@alignCast(context));
        return self.child.rawAlloc(len, alignment, return_address);
    }
    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        // Force allocate-copy-free so the old block always passes through free.
        return false;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *WipingAllocator = @ptrCast(@alignCast(context));
        std.crypto.secureZero(u8, memory);
        self.child.rawFree(memory, alignment, return_address);
    }
};

pub fn parseCommand(allocator: std.mem.Allocator, name: []const u8, payload: []const u8) !Parsed {
    if (payload.len > max_input_bytes) return error.InvalidRequest;
    const wiping = allocator.create(WipingAllocator) catch return error.OutOfMemory;
    wiping.* = .{ .child = allocator };
    var parsed = std.json.parseFromSlice(std.json.Value, wiping.allocator(), payload, .{ .allocate = .alloc_always }) catch {
        allocator.destroy(wiping);
        return error.InvalidRequest;
    };
    errdefer {
        parsed.deinit();
        allocator.destroy(wiping);
    }
    const command: Command = if (std.mem.eql(u8, name, "subwave.player.snapshot")) blk: {
        _ = try expectObjectFields(parsed.value, &.{});
        break :blk .snapshot;
    } else if (std.mem.eql(u8, name, "subwave.player.station.connect")) .{ .stationConnect = try parseConnect(parsed.value) } else if (std.mem.eql(u8, name, "subwave.player.station.cancel")) .{ .stationCancel = try parseOperationId(parsed.value) } else if (std.mem.eql(u8, name, "subwave.player.station.forget")) .{ .stationForget = try parseForget(parsed.value) } else if (std.mem.eql(u8, name, "subwave.player.station.disconnect")) blk: {
        _ = try expectObjectFields(parsed.value, &.{});
        break :blk .stationDisconnect;
    } else if (std.mem.eql(u8, name, "subwave.player.playback.command")) .{ .playbackCommand = try parsePlayback(parsed.value) } else if (std.mem.eql(u8, name, "subwave.player.preferences.update")) .{ .preferencesUpdate = try parsePreference(parsed.value) } else if (std.mem.eql(u8, name, "subwave.player.preferences.importLegacy")) blk: {
        _ = try expectObjectFields(parsed.value, &.{});
        break :blk .preferencesImportLegacy;
    } else return error.InvalidRequest;
    return .{ .json = parsed, .command = command, .parent_allocator = allocator, .wiping_allocator = wiping };
}

fn object(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |v| v,
        else => error.InvalidRequest,
    };
}
fn expectObjectFields(value: std.json.Value, allowed: []const []const u8) !std.json.ObjectMap {
    const map = try object(value);
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        var found = false;
        for (allowed) |field| if (std.mem.eql(u8, entry.key_ptr.*, field)) {
            found = true;
            break;
        };
        if (!found) return error.InvalidRequest;
    }
    return map;
}
fn required(map: std.json.ObjectMap, key: []const u8) !std.json.Value {
    return map.get(key) orelse error.InvalidRequest;
}
fn string(value: std.json.Value, max: usize) ![]const u8 {
    const result = switch (value) {
        .string => |v| v,
        else => return error.InvalidRequest,
    };
    if (result.len > max or !std.unicode.utf8ValidateSlice(result)) return error.InvalidRequest;
    return result;
}
fn boolean(value: std.json.Value) !bool {
    return switch (value) {
        .bool => |v| v,
        else => error.InvalidRequest,
    };
}
fn operationId(value: std.json.Value) !u64 {
    const id: u64 = switch (value) {
        .integer => |v| if (v > 0) @intCast(v) else return error.InvalidRequest,
        else => return error.InvalidRequest,
    };
    if (id > max_operation_id) return error.InvalidRequest;
    return id;
}
fn parseOperationId(value: std.json.Value) !u64 {
    const map = try expectObjectFields(value, &.{"operationId"});
    return operationId(try required(map, "operationId"));
}
fn parseForget(value: std.json.Value) ![]const u8 {
    const map = try expectObjectFields(value, &.{"id"});
    return stationId(try required(map, "id"));
}
fn stationId(value: std.json.Value) ![]const u8 {
    const id = try string(value, max_station_id_bytes);
    if (id.len != 64) return error.InvalidRequest;
    for (id) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidRequest;
    return id;
}

fn parseConnect(value: std.json.Value) !Connect {
    const map = try expectObjectFields(value, &.{ "address", "basic", "listenerPassword", "allowInsecureHttp" });
    const address = try string(try required(map, "address"), 1024);
    const basic = try parseCredentialEdit(try required(map, "basic"));
    const listener: ListenerPasswordEdit = if (map.get("listenerPassword")) |entry| switch (entry) {
        .null => .clear,
        .string => |v| .{ .replace = try string(.{ .string = v }, max_vault_secret_bytes) },
        else => return error.InvalidRequest,
    } else .keep;
    if (vaultSerializedBytes(basic, listener) > max_vault_secret_bytes) return error.InvalidRequest;
    return .{ .address = address, .basic = basic, .listenerPassword = listener, .allowInsecureHttp = try boolean(try required(map, "allowInsecureHttp")) };
}
fn parseCredentialEdit(value: std.json.Value) !CredentialEdit {
    const map = try object(value);
    const action = try string(try required(map, "action"), 7);
    if (std.mem.eql(u8, action, "keep")) {
        _ = try expectObjectFields(value, &.{"action"});
        return .keep;
    }
    if (std.mem.eql(u8, action, "clear")) {
        _ = try expectObjectFields(value, &.{"action"});
        return .clear;
    }
    if (!std.mem.eql(u8, action, "replace")) return error.InvalidRequest;
    _ = try expectObjectFields(value, &.{ "action", "username", "password" });
    return .{ .replace = .{ .username = try string(try required(map, "username"), max_vault_secret_bytes), .password = try string(try required(map, "password"), max_vault_secret_bytes) } };
}
fn escapedLen(value: []const u8) usize {
    var n: usize = 2;
    for (value) |b| n += if (b < 0x20) 6 else if (b == '"' or b == '\\') 2 else 1;
    return n;
}
fn vaultSerializedBytes(basic: CredentialEdit, listener: ListenerPasswordEdit) usize {
    var n: usize = 0;
    if (basic == .replace) {
        n += 27 + escapedLen(basic.replace.username) + escapedLen(basic.replace.password);
    }
    if (listener == .replace) n += escapedLen(listener.replace);
    return n;
}

fn parsePlayback(value: std.json.Value) !PlaybackCommand {
    const map = try object(value);
    const kind = try string(try required(map, "kind"), 8);
    if (std.mem.eql(u8, kind, "play") or std.mem.eql(u8, kind, "pause") or std.mem.eql(u8, kind, "stop")) {
        _ = try expectObjectFields(value, &.{"kind"});
        return if (kind[1] == 'l') .play else if (kind[1] == 'a') .pause else .stop;
    }
    _ = try expectObjectFields(value, &.{ "kind", "value" });
    const v = try required(map, "value");
    if (std.mem.eql(u8, kind, "volume")) {
        const f: f64 = switch (v) {
            .float => |x| x,
            .integer => |x| @floatFromInt(x),
            else => return error.InvalidRequest,
        };
        if (!std.math.isFinite(f) or f < 0 or f > 1) return error.InvalidRequest;
        return .{ .volume = f };
    }
    if (std.mem.eql(u8, kind, "mute")) return .{ .mute = try boolean(v) };
    if (std.mem.eql(u8, kind, "format")) return .{ .format = std.meta.stringToEnum(StreamFormat, try string(v, 4)) orelse return error.InvalidRequest };
    return error.InvalidRequest;
}
fn parsePreference(value: std.json.Value) !PreferenceUpdate {
    const map = try expectObjectFields(value, &.{ "key", "value" });
    const key = try string(try required(map, "key"), 32);
    const v = try required(map, "value");
    if (std.mem.eql(u8, key, "themeOverride")) return .{ .themeOverride = try string(v, max_theme_override_bytes) };
    if (std.mem.eql(u8, key, "discordClientId")) return .{ .discordClientId = try string(v, max_name_bytes) };
    if (std.mem.eql(u8, key, "discordEnabled")) return .{ .discordEnabled = try boolean(v) };
    if (std.mem.eql(u8, key, "notifyTrack")) return .{ .notifyTrack = try boolean(v) };
    return error.InvalidRequest;
}

pub fn writeSnapshot(snapshot: StationSnapshot, output: []u8) ![]const u8 {
    try validateSnapshot(snapshot);
    var writer = std.Io.Writer.fixed(output[0..@min(output.len, max_snapshot_bytes)]);
    std.json.Stringify.value(snapshot, .{ .emit_null_optional_fields = true }, &writer) catch return error.SnapshotTooLarge;
    return writer.buffered();
}

pub fn writeAccepted(value: Accepted, output: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output[0..@min(output.len, max_snapshot_bytes)]);
    if (value.ok) {
        if (value.@"error" != null) return error.InvalidResult;
        const id = value.operationId orelse return error.InvalidResult;
        if (id == 0 or id > max_operation_id) return error.InvalidResult;
        writer.print("{{\"ok\":true,\"operationId\":{d}}}", .{id}) catch return error.ResultTooLarge;
    } else {
        if (value.operationId != null) return error.InvalidResult;
        const result_error = value.@"error" orelse return error.InvalidResult;
        writer.print("{{\"ok\":false,\"error\":\"{s}\"}}", .{@tagName(result_error)}) catch return error.ResultTooLarge;
    }
    return writer.buffered();
}

pub fn writeOperationResult(value: OperationResult, output: []u8) ![]const u8 {
    if (value.operationId == 0 or value.operationId > max_operation_id) return error.InvalidResult;
    if (value.errorCode) |code| if (!validText(code, max_name_bytes)) return error.InvalidResult;
    var writer = std.Io.Writer.fixed(output[0..@min(output.len, max_snapshot_bytes)]);
    std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, &writer) catch return error.ResultTooLarge;
    return writer.buffered();
}
fn validText(value: []const u8, max: usize) bool {
    return value.len <= max and std.unicode.utf8ValidateSlice(value);
}
fn validateStation(value: Station) !void {
    if (!validText(value.base, max_canonical_base_bytes) or !validText(value.name, max_name_bytes)) return error.InvalidSnapshot;
    _ = stationId(.{ .string = value.id }) catch return error.InvalidSnapshot;
    var identity: identity_mod.StationIdentity = .{};
    _ = identity_mod.normalizeStation(value.base, &identity) catch return error.InvalidSnapshot;
    if (!std.mem.eql(u8, identity.base(), value.base) or !std.mem.eql(u8, &identity.id, value.id)) return error.InvalidSnapshot;
}
fn validateOperation(value: OperationStatus) !void {
    if (value.operationId == 0 or value.operationId > max_operation_id) return error.InvalidSnapshot;
    if (value.errorCode) |v| if (!validText(v, max_name_bytes)) return error.InvalidSnapshot;
}
fn validateSnapshot(value: StationSnapshot) !void {
    if (value.protocol != protocol_version or !std.math.isFinite(value.volume) or value.volume < 0 or value.volume > 1 or value.revision > max_operation_id or value.generation > max_operation_id) return error.InvalidSnapshot;
    if (value.retry) |retry| if (retry.dueInMs > max_operation_id) return error.InvalidSnapshot;
    if (value.station) |v| try validateStation(v);
    if (value.track) |v| {
        if (!validText(v.id, max_track_field_bytes) or !validText(v.title, max_track_field_bytes) or !validText(v.artist, max_track_field_bytes) or !validText(v.album, max_track_field_bytes)) return error.InvalidSnapshot;
    }
    if (value.recents.len > max_recents) return error.InvalidSnapshot;
    for (value.recents) |v| try validateStation(v);
    if (!validText(value.preferences.themeOverride, max_theme_override_bytes) or !validText(value.preferences.discordClientId, max_name_bytes)) return error.InvalidSnapshot;
    if (value.operations.station) |v| try validateOperation(v);
    if (value.operations.persistence) |v| try validateOperation(v);
    if (value.@"error") |v| if (!validText(v.code, max_name_bytes)) return error.InvalidSnapshot;
}

test "commands are closed and parsed storage owns transient secrets" {
    var parsed = try parseCommand(std.testing.allocator, "subwave.player.station.connect", "{\"address\":\"radio.example\",\"basic\":{\"action\":\"replace\",\"username\":\"u\",\"password\":\"p\"},\"listenerPassword\":null,\"allowInsecureHttp\":false}");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("p", parsed.command.stationConnect.basic.replace.password);
    try std.testing.expect(parsed.command.stationConnect.listenerPassword == .clear);
    try std.testing.expectError(error.InvalidRequest, parseCommand(std.testing.allocator, "subwave.player.station.disconnect", "{\"extra\":true}"));
    try std.testing.expectError(error.InvalidRequest, parseCommand(std.testing.allocator, "subwave.player.playback.command", "{\"kind\":\"play\",\"value\":1}"));
}

test "listener edit distinguishes omit clear and replace" {
    const prefix = "{\"address\":\"x.example\",\"basic\":{\"action\":\"keep\"},";
    var keep = try parseCommand(std.testing.allocator, "subwave.player.station.connect", prefix ++ "\"allowInsecureHttp\":false}");
    defer keep.deinit();
    var clear = try parseCommand(std.testing.allocator, "subwave.player.station.connect", prefix ++ "\"listenerPassword\":null,\"allowInsecureHttp\":false}");
    defer clear.deinit();
    var replace = try parseCommand(std.testing.allocator, "subwave.player.station.connect", prefix ++ "\"listenerPassword\":\"secret\",\"allowInsecureHttp\":false}");
    defer replace.deinit();
    try std.testing.expect(keep.command.stationConnect.listenerPassword == .keep);
    try std.testing.expect(clear.command.stationConnect.listenerPassword == .clear);
    try std.testing.expectEqualStrings("secret", replace.command.stationConnect.listenerPassword.replace);
}

test "all command branches accept their closed wire shapes" {
    const cases = [_]struct { name: []const u8, payload: []const u8 }{
        .{ .name = "subwave.player.snapshot", .payload = "{}" },
        .{ .name = "subwave.player.station.cancel", .payload = "{\"operationId\":1}" },
        .{ .name = "subwave.player.station.forget", .payload = "{\"id\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"}" },
        .{ .name = "subwave.player.station.disconnect", .payload = "{}" },
        .{ .name = "subwave.player.playback.command", .payload = "{\"kind\":\"pause\"}" },
        .{ .name = "subwave.player.playback.command", .payload = "{\"kind\":\"volume\",\"value\":0.5}" },
        .{ .name = "subwave.player.playback.command", .payload = "{\"kind\":\"mute\",\"value\":true}" },
        .{ .name = "subwave.player.playback.command", .payload = "{\"kind\":\"format\",\"value\":\"opus\"}" },
        .{ .name = "subwave.player.preferences.update", .payload = "{\"key\":\"themeOverride\",\"value\":\"night\"}" },
        .{ .name = "subwave.player.preferences.update", .payload = "{\"key\":\"discordEnabled\",\"value\":true}" },
        .{ .name = "subwave.player.preferences.importLegacy", .payload = "{}" },
    };
    for (cases) |case| {
        var parsed = try parseCommand(std.testing.allocator, case.name, case.payload);
        parsed.deinit();
    }
}

test "commands reject unknown duplicate unsafe and over-bound data" {
    const bad = [_]struct { name: []const u8, payload: []const u8 }{
        .{ .name = "subwave.player.unknown", .payload = "{}" },
        .{ .name = "subwave.player.snapshot", .payload = "{\"unknown\":1}" },
        .{ .name = "subwave.player.station.cancel", .payload = "{\"operationId\":1,\"operationId\":2}" },
        .{ .name = "subwave.player.station.cancel", .payload = "{\"operationId\":0}" },
        .{ .name = "subwave.player.station.cancel", .payload = "{\"operationId\":9007199254740992}" },
        .{ .name = "subwave.player.station.forget", .payload = "{\"id\":\"ABCDEF\"}" },
        .{ .name = "subwave.player.preferences.update", .payload = "{\"key\":\"notifyTrack\",\"value\":\"yes\"}" },
    };
    for (bad) |case| try std.testing.expectError(error.InvalidRequest, parseCommand(std.testing.allocator, case.name, case.payload));

    const secret = "s" ** max_vault_secret_bytes;
    const payload = try std.fmt.allocPrint(std.testing.allocator, "{{\"address\":\"x.example\",\"basic\":{{\"action\":\"replace\",\"username\":\"{s}\",\"password\":\"p\"}},\"allowInsecureHttp\":false}}", .{secret});
    defer std.testing.allocator.free(payload);
    try std.testing.expectError(error.InvalidRequest, parseCommand(std.testing.allocator, "subwave.player.station.connect", payload));
}

test "parsed teardown wipes owned JSON string values on success and validation error" {
    var success_storage: [8192]u8 = @splat(0xaa);
    var success_allocator = std.heap.FixedBufferAllocator.init(&success_storage);
    var parsed = try parseCommand(success_allocator.allocator(), "subwave.player.station.connect", "{\"address\":\"radio.example\",\"basic\":{\"action\":\"replace\",\"username\":\"wipe-user-sentinel\",\"password\":\"wipe-pass-sentinel\"},\"allowInsecureHttp\":false}");
    parsed.deinit();
    try std.testing.expect(std.mem.indexOf(u8, &success_storage, "wipe-user-sentinel") == null);
    try std.testing.expect(std.mem.indexOf(u8, &success_storage, "wipe-pass-sentinel") == null);

    var error_storage: [8192]u8 = @splat(0xaa);
    var error_allocator = std.heap.FixedBufferAllocator.init(&error_storage);
    try std.testing.expectError(error.InvalidRequest, parseCommand(error_allocator.allocator(), "subwave.player.station.connect", "{\"address\":\"radio.example\",\"basic\":{\"action\":\"replace\",\"username\":\"wipe-error-sentinel\",\"password\":\"p\",\"unknown\":true},\"allowInsecureHttp\":false}"));
    try std.testing.expect(std.mem.indexOf(u8, &error_storage, "wipe-error-sentinel") == null);

    var malformed_storage: [8192]u8 = @splat(0xaa);
    var malformed_allocator = std.heap.FixedBufferAllocator.init(&malformed_storage);
    try std.testing.expectError(error.InvalidRequest, parseCommand(malformed_allocator.allocator(), "subwave.player.station.connect", "{\"address\":\"radio.example\",\"basic\":{\"action\":\"replace\",\"username\":\"malformed-secret-sentinel\",\"password\":"));
    try std.testing.expect(std.mem.indexOf(u8, &malformed_storage, "malformed-secret-sentinel") == null);
}

test "accepted and operation result serializers match discriminated wire forms" {
    var output: [512]u8 = undefined;
    try std.testing.expectEqualStrings("{\"ok\":true,\"operationId\":41}", try writeAccepted(.{ .ok = true, .operationId = 41 }, &output));
    try std.testing.expectEqualStrings("{\"ok\":false,\"error\":\"busy\"}", try writeAccepted(.{ .ok = false, .@"error" = .busy }, &output));
    try std.testing.expectError(error.InvalidResult, writeAccepted(.{ .ok = true, .operationId = 0 }, &output));
    try std.testing.expectError(error.InvalidResult, writeAccepted(.{ .ok = false }, &output));
    try std.testing.expectEqualStrings("{\"operationId\":42,\"status\":\"succeeded\"}", try writeOperationResult(.{ .operationId = 42, .status = .succeeded }, &output));
    try std.testing.expectEqualStrings("{\"operationId\":43,\"status\":\"failed\",\"errorCode\":\"offline\"}", try writeOperationResult(.{ .operationId = 43, .status = .failed, .errorCode = "offline" }, &output));
    try std.testing.expectError(error.InvalidResult, writeOperationResult(.{ .operationId = max_operation_id + 1, .status = .failed }, &output));
    try std.testing.expectError(error.InvalidResult, writeOperationResult(.{ .operationId = 1, .status = .failed, .errorCode = "x" ** 65 }, &output));
}

test "operation error code is optional while required snapshot nulls remain explicit" {
    var identity: identity_mod.StationIdentity = .{};
    _ = try identity_mod.normalizeStation("https://radio.example", &identity);
    var output: [2048]u8 = undefined;
    const encoded = try writeSnapshot(.{ .revision = 1, .generation = 1, .playback = .stopped, .intent = .stopped, .buffering = false, .volume = 1, .muted = false, .station = null, .connection = .none, .retry = null, .track = null, .format = .mp3, .operations = .{ .station = .{ .operationId = 1, .status = .pending } } }, &output);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"errorCode\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"station\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"retry\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"track\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"error\":null") != null);
}

test "snapshot rejects retry times outside the JavaScript safe integer range" {
    var output: [2048]u8 = undefined;
    try std.testing.expectError(error.InvalidSnapshot, writeSnapshot(.{ .revision = 1, .generation = 1, .playback = .stopped, .intent = .stopped, .buffering = false, .volume = 1, .muted = false, .station = null, .connection = .offline, .retry = .{ .attempt = 1, .dueInMs = max_operation_id + 1 }, .track = null, .format = .mp3 }, &output));
}

test "snapshot omits credentials and fully escaped maximum fits bridge bound" {
    const base = "https://radio.example/" ++ ("x" ** 234);
    const escaped64 = "\x01" ** 64;
    const escaped128 = "\x01" ** 128;
    var identity: identity_mod.StationIdentity = .{};
    _ = try identity_mod.normalizeStation(base, &identity);
    const station = Station{ .id = &identity.id, .base = identity.base(), .name = escaped64 };
    const recents = [_]Station{station} ** max_recents;
    var output: [max_snapshot_bytes]u8 = undefined;
    const encoded = try writeSnapshot(.{ .revision = max_operation_id, .generation = max_operation_id, .playback = .playing, .intent = .playing, .buffering = true, .volume = 1, .muted = true, .station = station, .connection = .ready, .retry = .{ .attempt = std.math.maxInt(u32), .dueInMs = max_operation_id }, .track = .{ .id = escaped128, .title = escaped128, .artist = escaped128, .album = escaped128 }, .format = .flac, .operations = .{ .station = .{ .operationId = max_operation_id, .status = .failed, .errorCode = escaped64 }, .persistence = .{ .operationId = max_operation_id, .status = .failed, .errorCode = escaped64 } }, .recents = &recents, .preferences = .{ .themeOverride = escaped64, .discordEnabled = true, .discordClientId = escaped64, .notifyTrack = true }, .@"error" = .{ .code = escaped64, .retryable = true } }, &output);
    try std.testing.expect(encoded.len < max_snapshot_bytes);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "password") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "authorization") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "streamUrl") == null);
}
