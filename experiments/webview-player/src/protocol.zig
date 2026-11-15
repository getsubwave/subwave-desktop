const std = @import("std");

pub const Playback = enum { stopped, loading, playing, paused, @"error" };

pub const Snapshot = struct {
    protocol: u8 = 1,
    revision: u64 = 0,
    generation: u64 = 1,
    playback: Playback = .stopped,
    volume: f32 = 1,
    error_message: ?[]const u8 = null,
};

pub const Command = union(enum) {
    play,
    pause,
    stop,
    volume: f32,
};

pub const WindowAction = enum { openMini, closeMini, hideMain, showMain };

pub fn parseCommand(payload: []const u8) !Command {
    const Wire = struct { kind: []const u8, value: ?f64 = null };
    const parsed = std.json.parseFromSlice(Wire, std.heap.page_allocator, payload, .{ .ignore_unknown_fields = false }) catch return error.InvalidRequest;
    defer parsed.deinit();
    const wire = parsed.value;
    if (std.mem.eql(u8, wire.kind, "play") and wire.value == null) return .play;
    if (std.mem.eql(u8, wire.kind, "pause") and wire.value == null) return .pause;
    if (std.mem.eql(u8, wire.kind, "stop") and wire.value == null) return .stop;
    if (std.mem.eql(u8, wire.kind, "volume")) {
        const value = wire.value orelse return error.InvalidRequest;
        if (!std.math.isFinite(value) or value < 0 or value > 1) return error.InvalidRequest;
        return .{ .volume = @floatCast(value) };
    }
    return error.InvalidRequest;
}

pub fn parseWindowAction(payload: []const u8) !WindowAction {
    const Wire = struct { action: []const u8 };
    const parsed = std.json.parseFromSlice(Wire, std.heap.page_allocator, payload, .{ .ignore_unknown_fields = false }) catch return error.InvalidRequest;
    defer parsed.deinit();
    inline for (std.meta.fields(WindowAction)) |field| {
        if (std.mem.eql(u8, parsed.value.action, field.name)) return @enumFromInt(field.value);
    }
    return error.InvalidRequest;
}

pub fn parseSpectrumAck(payload: []const u8) !u64 {
    const Wire = struct { sequence: u64 };
    const parsed = std.json.parseFromSlice(Wire, std.heap.page_allocator, payload, .{ .ignore_unknown_fields = false }) catch return error.InvalidRequest;
    defer parsed.deinit();
    return parsed.value.sequence;
}

pub fn writeSnapshot(snapshot: Snapshot, output: []u8) ![]const u8 {
    var out = std.Io.Writer.fixed(output);
    try out.print("{{\"protocol\":1,\"revision\":{d},\"generation\":{d},\"playback\":\"{s}\",\"volume\":{d},\"error\":", .{
        snapshot.revision, snapshot.generation, @tagName(snapshot.playback), snapshot.volume,
    });
    if (snapshot.error_message) |message| {
        var escaped: [1024]u8 = undefined;
        try out.writeAll(@import("native_sdk").bridge.writeJsonStringValue(&escaped, message));
    } else try out.writeAll("null");
    try out.writeByte('}');
    return out.buffered();
}

test "command validation rejects malformed and invalid volume" {
    try std.testing.expectError(error.InvalidRequest, parseCommand("{}"));
    try std.testing.expectError(error.InvalidRequest, parseCommand("{\"kind\":\"unknown\"}"));
    try std.testing.expectError(error.InvalidRequest, parseCommand("{\"kind\":\"volume\",\"value\":-0.1}"));
    try std.testing.expectError(error.InvalidRequest, parseCommand("{\"kind\":\"volume\",\"value\":1.1}"));
    try std.testing.expectError(error.InvalidRequest, parseCommand("{\"kind\":\"volume\",\"value\":\"NaN\"}"));
    try std.testing.expectEqual(Command.play, try parseCommand("{\"kind\":\"play\"}"));
}

test "snapshot has the protocol one wire shape" {
    var buffer: [512]u8 = undefined;
    const json = try writeSnapshot(.{ .revision = 4, .generation = 2, .playback = .paused, .volume = 0.5 }, &buffer);
    try std.testing.expectEqualStrings("{\"protocol\":1,\"revision\":4,\"generation\":2,\"playback\":\"paused\",\"volume\":0.5,\"error\":null}", json);
}
