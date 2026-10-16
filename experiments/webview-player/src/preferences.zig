//! Pure, bounded version-2 nonsecret preferences codec and station MRU.
const std = @import("std");
const identity_mod = @import("station_identity.zig");
const protocol = @import("station_protocol.zig");

pub const version: u8 = 2;
pub const max_input_bytes: usize = 8 * 1024;
pub const max_output_bytes: usize = 8 * 1024;
pub const max_stations: usize = 8;
pub const max_name_bytes: usize = 64;
pub const max_theme_bytes: usize = 64;
pub const max_discord_id_bytes: usize = 20;

pub const StreamFormat = protocol.StreamFormat;
pub const Station = struct {
    id: []const u8,
    base: []const u8,
    name: []const u8,
    streamFormat: StreamFormat = .mp3,
    allowInsecureHttp: bool = false,
};
pub const LegacyImport = struct { completed: bool = false, sourceDigest: ?[]const u8 = null };
pub const Preferences = struct {
    volume: f64 = 0.8,
    themeOverride: []const u8 = "",
    activeStationId: ?[]const u8 = null,
    pendingRemoval: ?[]const u8 = null,
    stations: []const Station = &.{},
    discordEnabled: bool = false,
    discordClientId: []const u8 = "",
    notifyTrack: bool = false,
    legacyImport: LegacyImport = .{},
};

pub const Decoded = struct {
    arena: std.heap.ArenaAllocator,
    value: Preferences,
    pub fn deinit(self: *Decoded) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const Raw = struct {
    version: u8,
    volume: f64 = 0.8,
    themeOverride: []const u8 = "",
    activeStationId: ?[]const u8 = null,
    pendingRemoval: ?[]const u8 = null,
    stations: []const Station = &.{},
    discordEnabled: bool = false,
    discordClientId: []const u8 = "",
    notifyTrack: bool = false,
    legacyImport: LegacyImport = .{},
};

fn validText(value: []const u8, max: usize) bool {
    return value.len <= max and std.unicode.utf8ValidateSlice(value);
}

fn validDiscordId(value: []const u8) bool {
    if (value.len == 0) return true;
    if (value.len < 17 or value.len > max_discord_id_bytes) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn validateStation(station: Station) !void {
    if (!validText(station.name, max_name_bytes) or station.id.len != 64) return error.InvalidPreferences;
    var normalized: identity_mod.StationIdentity = .{};
    _ = identity_mod.normalizeStation(station.base, &normalized) catch return error.InvalidPreferences;
    if (!std.mem.eql(u8, normalized.base(), station.base) or !std.mem.eql(u8, &normalized.id, station.id)) return error.InvalidPreferences;
}

pub fn validate(value: Preferences) !void {
    if (!std.math.isFinite(value.volume) or value.volume < 0 or value.volume > 1 or !validText(value.themeOverride, max_theme_bytes) or !validDiscordId(value.discordClientId)) return error.InvalidPreferences;
    if (value.stations.len > max_stations) return error.InvalidPreferences;
    for (value.stations, 0..) |station, i| {
        try validateStation(station);
        for (value.stations[0..i]) |prior| if (std.mem.eql(u8, prior.id, station.id)) return error.InvalidPreferences;
    }
    if (value.activeStationId) |active| {
        if (active.len != 64) return error.InvalidPreferences;
        var found = false;
        for (value.stations) |station| found = found or std.mem.eql(u8, station.id, active);
        if (!found) return error.InvalidPreferences;
    }
    if (value.pendingRemoval) |pending| {
        if (pending.len != 64) return error.InvalidPreferences;
        var found = false;
        for (value.stations) |station| found = found or std.mem.eql(u8, station.id, pending);
        if (!found) return error.InvalidPreferences;
    }
    if (value.legacyImport.sourceDigest) |digest| {
        if (digest.len != 64) return error.InvalidPreferences;
        for (digest) |byte| if (!std.ascii.isHex(byte)) return error.InvalidPreferences;
    }
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Decoded {
    if (bytes.len > max_input_bytes) return error.PreferencesTooLarge;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const raw = try std.json.parseFromSliceLeaky(Raw, arena.allocator(), bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    if (raw.version != version) return error.UnsupportedPreferencesVersion;
    if (!std.math.isFinite(raw.volume)) return error.InvalidPreferences;
    const value: Preferences = .{
        .volume = std.math.clamp(raw.volume, 0, 1),
        .themeOverride = raw.themeOverride,
        .activeStationId = raw.activeStationId,
        .pendingRemoval = raw.pendingRemoval,
        .stations = raw.stations,
        .discordEnabled = raw.discordEnabled,
        // Match the shipping desktop behavior: a hand-edited invalid public
        // application ID is dropped rather than poisoning all preferences.
        .discordClientId = if (validDiscordId(raw.discordClientId)) raw.discordClientId else "",
        .notifyTrack = raw.notifyTrack,
        .legacyImport = raw.legacyImport,
    };
    try validate(value);
    return .{ .arena = arena, .value = value };
}

pub fn encode(value: Preferences, output: []u8) ![]const u8 {
    try validate(value);
    const bounded_output = output[0..@min(output.len, max_output_bytes)];
    var writer = std.Io.Writer.fixed(bounded_output);
    std.json.Stringify.value(struct {
        version: u8 = version,
        volume: f64,
        themeOverride: []const u8,
        activeStationId: ?[]const u8,
        pendingRemoval: ?[]const u8,
        stations: []const Station,
        discordEnabled: bool,
        discordClientId: []const u8,
        notifyTrack: bool,
        legacyImport: LegacyImport,
    }{ .volume = value.volume, .themeOverride = value.themeOverride, .activeStationId = value.activeStationId, .pendingRemoval = value.pendingRemoval, .stations = value.stations, .discordEnabled = value.discordEnabled, .discordClientId = value.discordClientId, .notifyTrack = value.notifyTrack, .legacyImport = value.legacyImport }, .{ .emit_null_optional_fields = true }, &writer) catch return error.PreferencesTooLarge;
    return writer.buffered();
}

/// Pushes a validated station to the front, deduplicating by stable identity.
pub fn pushRecent(arena: std.mem.Allocator, value: *Preferences, station: Station) !void {
    try validateStation(station);
    var next = try arena.alloc(Station, @min(value.stations.len + 1, max_stations));
    next[0] = .{ .id = try arena.dupe(u8, station.id), .base = try arena.dupe(u8, station.base), .name = try arena.dupe(u8, station.name), .streamFormat = station.streamFormat, .allowInsecureHttp = station.allowInsecureHttp };
    var out: usize = 1;
    for (value.stations) |old| {
        if (std.mem.eql(u8, old.id, station.id)) continue;
        if (out == next.len) break;
        next[out] = old;
        out += 1;
    }
    value.stations = next[0..out];
}

test "defaults decode and bounded round trip preserve documented preferences" {
    var decoded = try decode(std.testing.allocator, "{\"version\":2}");
    defer decoded.deinit();
    try std.testing.expectEqual(@as(f64, 0.8), decoded.value.volume);
    try std.testing.expectEqual(StreamFormat.mp3, if (decoded.value.stations.len == 0) .mp3 else decoded.value.stations[0].streamFormat);
    try std.testing.expect(!decoded.value.discordEnabled and !decoded.value.notifyTrack);
    try std.testing.expect(decoded.value.pendingRemoval == null);
    var output: [max_output_bytes]u8 = undefined;
    const json = try encode(decoded.value, &output);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"version\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"pendingRemoval\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "skin") == null);
}

test "volume clamps while invalid ids, text, versions, and station consent fail" {
    var high = try decode(std.testing.allocator, "{\"version\":2,\"volume\":4}");
    defer high.deinit();
    try std.testing.expectEqual(@as(f64, 1), high.value.volume);
    try std.testing.expectError(error.UnsupportedPreferencesVersion, decode(std.testing.allocator, "{\"version\":1}"));
    var invalid_discord = try decode(std.testing.allocator, "{\"version\":2,\"discordEnabled\":true,\"discordClientId\":\"abc\"}");
    defer invalid_discord.deinit();
    try std.testing.expectEqualStrings("", invalid_discord.value.discordClientId);
    try std.testing.expect(invalid_discord.value.discordEnabled);
    try std.testing.expectError(error.InvalidPreferences, decode(std.testing.allocator, "{\"version\":2,\"volume\":1e999}"));
    var output: [max_output_bytes]u8 = undefined;
    try std.testing.expectError(error.InvalidPreferences, encode(.{ .volume = -0.01 }, &output));
    try std.testing.expectError(error.InvalidPreferences, encode(.{ .volume = 1.01 }, &output));
    const insecure = "{\"version\":2,\"stations\":[{\"id\":\"d97b7bbbcf6fc528a380e61f2dc80c35d10d5dd83fbf1fca6d3c930b930e5be4\",\"base\":\"http://radio.example\",\"name\":\"Radio\",\"streamFormat\":\"mp3\",\"allowInsecureHttp\":false}]}";
    try std.testing.expectError(error.InvalidPreferences, decode(std.testing.allocator, insecure));
}

test "decoded strings are owned and active station must reference its MRU" {
    var station_identity: identity_mod.StationIdentity = .{};
    _ = try identity_mod.normalizeStation("radio.example", &station_identity);
    var body: [1024]u8 = undefined;
    const json = try std.fmt.bufPrint(&body, "{{\"version\":2,\"activeStationId\":\"{s}\",\"stations\":[{{\"id\":\"{s}\",\"base\":\"{s}\",\"name\":\"Owned Radio\",\"streamFormat\":\"aac\",\"allowInsecureHttp\":false}}]}}", .{ &station_identity.id, &station_identity.id, station_identity.base() });
    var decoded = try decode(std.testing.allocator, json);
    defer decoded.deinit();
    @memset(body[0..json.len], 'x');
    try std.testing.expectEqualStrings("Owned Radio", decoded.value.stations[0].name);
    try std.testing.expectEqual(StreamFormat.aac, decoded.value.stations[0].streamFormat);

    const orphan = "{\"version\":2,\"activeStationId\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}";
    try std.testing.expectError(error.InvalidPreferences, decode(std.testing.allocator, orphan));
}

test "pending removal is canonical and references a retained recent station" {
    var station_identity: identity_mod.StationIdentity = .{};
    _ = try identity_mod.normalizeStation("radio.example", &station_identity);
    var body: [1024]u8 = undefined;
    const valid = try std.fmt.bufPrint(&body, "{{\"version\":2,\"pendingRemoval\":\"{s}\",\"stations\":[{{\"id\":\"{s}\",\"base\":\"{s}\",\"name\":\"Radio\"}}]}}", .{ &station_identity.id, &station_identity.id, station_identity.base() });
    var decoded = try decode(std.testing.allocator, valid);
    defer decoded.deinit();
    try std.testing.expectEqualStrings(&station_identity.id, decoded.value.pendingRemoval.?);
    try std.testing.expectError(error.InvalidPreferences, decode(std.testing.allocator, "{\"version\":2,\"pendingRemoval\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}"));
    try std.testing.expectError(error.InvalidPreferences, decode(std.testing.allocator, "{\"version\":2,\"pendingRemoval\":\"ABCDEF\"}"));
}

test "MRU deduplicates, replaces metadata, and caps at eight" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var value: Preferences = .{};
    var identities: [9]identity_mod.StationIdentity = @splat(.{});
    var names: [9][8]u8 = undefined;
    for (0..9) |i| {
        var raw: [32]u8 = undefined;
        const base = try std.fmt.bufPrint(&raw, "radio{d}.example", .{i});
        _ = try identity_mod.normalizeStation(base, &identities[i]);
        const name = try std.fmt.bufPrint(&names[i], "Radio {d}", .{i});
        try pushRecent(arena.allocator(), &value, .{ .id = &identities[i].id, .base = identities[i].base(), .name = name });
    }
    try std.testing.expectEqual(max_stations, value.stations.len);
    try std.testing.expectEqualStrings("Radio 8", value.stations[0].name);
    try pushRecent(arena.allocator(), &value, .{ .id = &identities[5].id, .base = identities[5].base(), .name = "Renamed", .streamFormat = .flac });
    try std.testing.expectEqual(max_stations, value.stations.len);
    try std.testing.expectEqualStrings("Renamed", value.stations[0].name);
    try std.testing.expectEqual(StreamFormat.flac, value.stations[0].streamFormat);
}
