//! Pure credential records and encoding policy. Platform vault I/O is external.
const std = @import("std");

pub const max_key_bytes: usize = 256;
pub const max_secret_bytes: usize = 2560;
pub const max_effect_header_bytes: usize = 1024;
// Reserve the header names and JSON Content-Type used by station-auth too.
pub const max_authorization_bytes = max_effect_header_bytes - "Authorization".len - "Content-Type".len - "application/json".len;

pub const Outcome = enum { ok, miss, locked, denied, io_failed, over_bound, rejected };
pub const Kind = enum { basic, listener };

pub const BasicRecord = struct {
    username_storage: [max_secret_bytes]u8 = undefined,
    username_len: u16 = 0,
    password_storage: [max_secret_bytes]u8 = undefined,
    password_len: u16 = 0,

    pub fn init(username_value: []const u8, password_value: []const u8) !BasicRecord {
        if (!std.unicode.utf8ValidateSlice(username_value) or !std.unicode.utf8ValidateSlice(password_value)) return error.InvalidUtf8;
        if (username_value.len > max_secret_bytes or password_value.len > max_secret_bytes) return error.OverBound;
        if (basicSerializedLen(username_value, password_value) > max_secret_bytes) return error.OverBound;
        var result: BasicRecord = .{};
        @memcpy(result.username_storage[0..username_value.len], username_value);
        @memcpy(result.password_storage[0..password_value.len], password_value);
        result.username_len = @intCast(username_value.len);
        result.password_len = @intCast(password_value.len);
        return result;
    }
    pub fn parse(bytes: []const u8) !BasicRecord {
        if (bytes.len > max_secret_bytes) return error.OverBound;
        var scratch: [16 * 1024]u8 = undefined;
        defer std.crypto.secureZero(u8, &scratch);
        var allocator = std.heap.FixedBufferAllocator.init(&scratch);
        const Parsed = struct { username: []const u8, password: []const u8 };
        const parsed = std.json.parseFromSlice(Parsed, allocator.allocator(), bytes, .{ .allocate = .alloc_always }) catch return error.InvalidRecord;
        defer parsed.deinit();
        return BasicRecord.init(parsed.value.username, parsed.value.password);
    }
    pub fn username(self: *const BasicRecord) []const u8 {
        return self.username_storage[0..self.username_len];
    }
    pub fn password(self: *const BasicRecord) []const u8 {
        return self.password_storage[0..self.password_len];
    }
    pub fn deinit(self: *BasicRecord) void {
        std.crypto.secureZero(u8, &self.username_storage);
        std.crypto.secureZero(u8, &self.password_storage);
        self.username_len = 0;
        self.password_len = 0;
    }
};

pub const ListenerRecord = struct {
    storage: [max_secret_bytes]u8 = undefined,
    len: u16 = 0,

    pub fn init(password_value: []const u8) !ListenerRecord {
        if (!std.unicode.utf8ValidateSlice(password_value)) return error.InvalidUtf8;
        if (password_value.len > max_secret_bytes) return error.OverBound;
        var result: ListenerRecord = .{};
        @memcpy(result.storage[0..password_value.len], password_value);
        result.len = @intCast(password_value.len);
        return result;
    }
    pub fn password(self: *const ListenerRecord) []const u8 {
        return self.storage[0..self.len];
    }
    pub fn deinit(self: *ListenerRecord) void {
        std.crypto.secureZero(u8, &self.storage);
        self.len = 0;
    }
};

pub const BasicEdit = union(enum) { keep, clear, replace: *const BasicRecord };
pub const ListenerEdit = union(enum) { keep, clear, replace: *const ListenerRecord };
pub const Mutation = enum { none, delete, set };

pub fn basicMutation(edit: BasicEdit) Mutation {
    return switch (edit) {
        .keep => .none,
        .clear => .delete,
        .replace => .set,
    };
}
pub fn listenerMutation(edit: ListenerEdit) Mutation {
    return switch (edit) {
        .keep => .none,
        .clear => .delete,
        .replace => .set,
    };
}

pub fn writeKey(kind: Kind, station_id: []const u8, output: []u8) ![]const u8 {
    if (station_id.len != 64) return error.InvalidStationId;
    for (station_id) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidStationId;
    const prefix = @tagName(kind);
    const needed = prefix.len + 1 + station_id.len;
    if (needed > max_key_bytes or output.len < needed) return error.OverBound;
    return std.fmt.bufPrint(output, "{s}:{s}", .{ prefix, station_id }) catch error.OverBound;
}

pub fn writeBasicRecord(record: *const BasicRecord, output: []u8) ![]const u8 {
    if (output.len < basicSerializedLen(record.username(), record.password())) return error.OverBound;
    var writer = std.Io.Writer.fixed(output[0..@min(output.len, max_secret_bytes)]);
    writer.writeAll("{\"username\":") catch return error.OverBound;
    writeJsonString(&writer, record.username()) catch return error.OverBound;
    writer.writeAll(",\"password\":") catch return error.OverBound;
    writeJsonString(&writer, record.password()) catch return error.OverBound;
    writer.writeByte('}') catch return error.OverBound;
    return writer.buffered();
}

/// Produce a standard UTF-8 Basic header. The Effects header budget is
/// checked before writing and credentials are never shortened.
pub fn writeAuthorization(record: *const BasicRecord, output: []u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, record.username(), ':') != null) return error.InvalidUsername;
    var plain: [max_secret_bytes * 2 + 1]u8 = undefined;
    defer std.crypto.secureZero(u8, &plain);
    const plain_len = record.username().len + 1 + record.password().len;
    @memcpy(plain[0..record.username().len], record.username());
    plain[record.username().len] = ':';
    @memcpy(plain[record.username().len + 1 .. plain_len], record.password());
    const encoded_len = std.base64.standard.Encoder.calcSize(plain_len);
    const total = "Basic ".len + encoded_len;
    if (total > max_authorization_bytes) return error.HeaderTooLarge;
    if (output.len < total) return error.OverBound;
    @memcpy(output[0.."Basic ".len], "Basic ");
    _ = std.base64.standard.Encoder.encode(output["Basic ".len..total], plain[0..plain_len]);
    return output[0..total];
}

/// Encode the listener password solely as the stream query component.
pub fn writeListenerQuery(record: *const ListenerRecord, output: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    writer.writeAll("auth=") catch return error.OverBound;
    for (record.password()) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~') {
            writer.writeByte(byte) catch return error.OverBound;
        } else {
            writer.print("%{X:0>2}", .{byte}) catch return error.OverBound;
        }
    }
    return writer.buffered();
}

pub const ImportDecision = union(enum) { keep_secure, no_value, write_legacy, failed: Outcome };

/// Secure storage is authoritative. Only a confirmed miss permits legacy
/// credentials to be imported; every read failure remains distinct.
pub fn importBasic(existing: Outcome, has_legacy: bool) ImportDecision {
    return switch (existing) {
        .ok => .keep_secure,
        .miss => if (has_legacy) .write_legacy else .no_value,
        .locked => .{ .failed = .locked },
        .denied => .{ .failed = .denied },
        .io_failed => .{ .failed = .io_failed },
        .over_bound => .{ .failed = .over_bound },
        .rejected => .{ .failed = .rejected },
    };
}

fn basicSerializedLen(username: []const u8, password: []const u8) usize {
    return 25 + jsonStringLen(username) + jsonStringLen(password);
}
fn jsonStringLen(value: []const u8) usize {
    var result: usize = 2;
    for (value) |byte| result += if (byte < 0x20) 6 else if (byte == '"' or byte == '\\') 2 else 1;
    return result;
}
fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    writer.writeByte('"') catch return error.WriteFailed;
    for (value) |byte| switch (byte) {
        '"' => writer.writeAll("\\\"") catch return error.WriteFailed,
        '\\' => writer.writeAll("\\\\") catch return error.WriteFailed,
        0...0x1f => writer.print("\\u00{X:0>2}", .{byte}) catch return error.WriteFailed,
        else => writer.writeByte(byte) catch return error.WriteFailed,
    };
    writer.writeByte('"') catch return error.WriteFailed;
}

test "vault keys separate credential kinds and accept only canonical ids" {
    const id = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    var output: [256]u8 = undefined;
    try std.testing.expectEqualStrings("basic:" ++ id, try writeKey(.basic, id, &output));
    try std.testing.expectEqualStrings("listener:" ++ id, try writeKey(.listener, id, &output));
    try std.testing.expectError(error.InvalidStationId, writeKey(.basic, "ABC", &output));
}

test "Basic authorization uses UTF-8 and enforces Effects header budget" {
    var record = try BasicRecord.init("fixture-üser", "fixture-päss:雪");
    defer record.deinit();
    var output: [max_effect_header_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("Basic Zml4dHVyZS3DvHNlcjpmaXh0dXJlLXDDpHNzOumbqg==", try writeAuthorization(&record, &output));
    var large = try BasicRecord.init("u", "p" ** 800);
    defer large.deinit();
    try std.testing.expectError(error.HeaderTooLarge, writeAuthorization(&large, &output));
}

test "serialized record cap accounts for JSON escaping without truncation" {
    var acceptable = try BasicRecord.init("u", "\\" ** 1200);
    defer acceptable.deinit();
    var output: [max_secret_bytes]u8 = undefined;
    const encoded = try writeBasicRecord(&acceptable, &output);
    try std.testing.expect(encoded.len <= max_secret_bytes);
    try std.testing.expectError(error.OverBound, BasicRecord.init("u", "\x01" ** 500));
    var exact = try BasicRecord.init("u", "p" ** 2530);
    defer exact.deinit();
    try std.testing.expectEqual(@as(usize, max_secret_bytes), (try writeBasicRecord(&exact, &output)).len);
    try std.testing.expectError(error.OverBound, BasicRecord.init("u", "p" ** 2531));
}

test "listener query percent-encodes UTF-8 and query delimiters" {
    var listener = try ListenerRecord.init("pä ss&雪=?");
    defer listener.deinit();
    var output: [256]u8 = undefined;
    try std.testing.expectEqualStrings("auth=p%C3%A4%20ss%26%E9%9B%AA%3D%3F", try writeListenerQuery(&listener, &output));
}

test "edits distinguish keep clear replace" {
    var basic = try BasicRecord.init("u", "p");
    defer basic.deinit();
    try std.testing.expectEqual(Mutation.none, basicMutation(.keep));
    try std.testing.expectEqual(Mutation.delete, basicMutation(.clear));
    try std.testing.expectEqual(Mutation.set, basicMutation(.{ .replace = &basic }));
}

test "import preserves secure data and never treats failure as miss" {
    var secure = try BasicRecord.init("secure", "new");
    defer secure.deinit();
    var legacy = try BasicRecord.init("legacy", "old");
    defer legacy.deinit();
    try std.testing.expect(importBasic(.ok, true) == .keep_secure);
    try std.testing.expect(importBasic(.miss, true) == .write_legacy);
    try std.testing.expect(importBasic(.miss, false) == .no_value);
    try std.testing.expectEqual(Outcome.locked, importBasic(.locked, true).failed);
    try std.testing.expectEqual(Outcome.io_failed, importBasic(.io_failed, true).failed);
}

test "owned records securely clear their backing storage" {
    var record = try BasicRecord.init("wipe-user", "wipe-password");
    const username = record.username_storage[0..];
    const password = record.password_storage[0..];
    record.deinit();
    try std.testing.expect(std.mem.allEqual(u8, username, 0));
    try std.testing.expect(std.mem.allEqual(u8, password, 0));
}

test "vault record parse owns escaped credentials and header preflight includes metadata" {
    var record = try BasicRecord.parse("{\"username\":\"u\",\"password\":\"p\\u00e4ss\"}");
    defer record.deinit();
    try std.testing.expectEqualStrings("päss", record.password());
    try std.testing.expectError(error.InvalidRecord, BasicRecord.parse("{\"username\":\"u\"}"));
    try std.testing.expectError(error.InvalidRecord, BasicRecord.parse("{\"username\":\"u\",\"password\":\"p\",\"password\":\"q\"}"));
    var large = try BasicRecord.init("u", "p" ** 740);
    defer large.deinit();
    var output: [1024]u8 = undefined;
    try std.testing.expectError(error.HeaderTooLarge, writeAuthorization(&large, &output));
    var ambiguous = try BasicRecord.init("u:v", "p");
    defer ambiguous.deinit();
    try std.testing.expectError(error.InvalidUsername, writeAuthorization(&ambiguous, &output));
}
