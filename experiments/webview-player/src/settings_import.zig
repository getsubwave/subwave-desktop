//! Pure parser for a legacy settings blob. Filesystem/vault transactions live elsewhere.
const std = @import("std");
const preferences_mod = @import("preferences.zig");
const vault = @import("credential_vault.zig");
const identity_mod = @import("station_identity.zig");

pub const max_source_bytes: usize = 8192;

pub const CredentialCandidate = struct {
    basic: ?vault.BasicRecord = null,
    listener: ?vault.ListenerRecord = null,
};

pub const Candidate = struct {
    parent_allocator: std.mem.Allocator,
    wiping_allocator: *WipingAllocator,
    arena: std.heap.ArenaAllocator,
    preferences: preferences_mod.Preferences,
    credentials: [preferences_mod.max_stations]CredentialCandidate = @splat(.{}),
    source_digest: [32]u8,

    pub fn deinit(self: *Candidate) void {
        for (&self.credentials) |*credential| {
            if (credential.basic) |*record| record.deinit();
            if (credential.listener) |*record| record.deinit();
        }
        self.arena.deinit();
        self.parent_allocator.destroy(self.wiping_allocator);
        self.* = undefined;
    }
};

const RawRecent = struct { name: ?[]const u8 = null, url: ?[]const u8 = null };
const RawSettings = struct {
    volume: ?f64 = null,
    themeOverride: ?[]const u8 = null,
    streamFormat: ?[]const u8 = null,
    station: ?[]const u8 = null,
    stationName: ?[]const u8 = null,
    stationPassword: ?[]const u8 = null,
    recents: ?[]RawRecent = null,
    discordEnabled: ?bool = null,
    discordClientId: ?[]const u8 = null,
    notifyTrack: ?bool = null,
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

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Candidate {
    if (source.len > max_source_bytes) return error.LegacySettingsTooLarge;
    const wiping = try allocator.create(WipingAllocator);
    errdefer allocator.destroy(wiping);
    wiping.* = .{ .child = allocator };
    var arena = std.heap.ArenaAllocator.init(wiping.allocator());
    errdefer arena.deinit();
    const a = arena.allocator();
    const raw = std.json.parseFromSliceLeaky(RawSettings, a, source, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return error.InvalidLegacySettings;
    if (raw.volume) |volume| if (!std.math.isFinite(volume)) return error.InvalidLegacySettings;
    const theme = raw.themeOverride orelse "";
    if (!validText(theme, preferences_mod.max_theme_bytes)) return error.InvalidLegacySettings;
    const discord_id = if (validDiscordId(raw.discordClientId orelse "")) raw.discordClientId orelse "" else "";

    const stations = try a.alloc(preferences_mod.Station, preferences_mod.max_stations);
    var credentials: [preferences_mod.max_stations]CredentialCandidate = @splat(.{});
    errdefer wipeCredentials(&credentials);
    var count: usize = 0;
    var active_id: ?[]const u8 = null;
    const active_format = parseFormat(raw.streamFormat orelse "");
    if (raw.station) |station_url| {
        if (station_url.len > 0) {
            if (try appendStation(a, stations, &credentials, &count, station_url, raw.stationName, active_format)) |index| {
                active_id = stations[index].id;
                if (raw.stationPassword) |password| {
                    if (password.len > 0)
                        credentials[index].listener = vault.ListenerRecord.init(password) catch return error.InvalidLegacySettings;
                }
            }
        }
    }
    if (raw.recents) |recents| for (recents) |recent| {
        if (count == preferences_mod.max_stations) break;
        const url = recent.url orelse continue;
        if (url.len == 0) continue;
        _ = try appendStation(a, stations, &credentials, &count, url, recent.name, .mp3);
    };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    const prefs: preferences_mod.Preferences = .{
        .volume = std.math.clamp(raw.volume orelse 0.8, 0, 1),
        .themeOverride = theme,
        .activeStationId = active_id,
        .stations = stations[0..count],
        .discordEnabled = raw.discordEnabled orelse false,
        .discordClientId = discord_id,
        .notifyTrack = raw.notifyTrack orelse false,
        // The transaction layer alone may mark this source committed.
        .legacyImport = .{},
    };
    try preferences_mod.validate(prefs);
    return .{ .parent_allocator = allocator, .wiping_allocator = wiping, .arena = arena, .preferences = prefs, .credentials = credentials, .source_digest = digest };
}

fn appendStation(a: std.mem.Allocator, stations: []preferences_mod.Station, credentials: *[preferences_mod.max_stations]CredentialCandidate, count: *usize, legacy_url: []const u8, maybe_name: ?[]const u8, format: preferences_mod.StreamFormat) !?usize {
    var clean_storage: [identity_mod.max_input_bytes]u8 = undefined;
    var username_storage: [vault.max_secret_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &username_storage);
    var password_storage: [vault.max_secret_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &password_storage);
    const extracted = extractLegacyUrl(legacy_url, &clean_storage, &username_storage, &password_storage) catch return error.InvalidLegacySettings;
    var identity: identity_mod.StationIdentity = .{};
    _ = identity_mod.normalizeStation(extracted.clean, &identity) catch return error.InvalidLegacySettings;
    for (stations[0..count.*], 0..) |existing, index| if (std.mem.eql(u8, existing.id, &identity.id)) return index;
    if (count.* == stations.len) return null;
    const name = maybe_name orelse "";
    if (!validText(name, preferences_mod.max_name_bytes)) return error.InvalidLegacySettings;
    const index = count.*;
    stations[index] = .{
        .id = try a.dupe(u8, &identity.id),
        .base = try a.dupe(u8, identity.base()),
        .name = try a.dupe(u8, name),
        .streamFormat = format,
        .allowInsecureHttp = false, // Import does not grant new cleartext credential consent.
    };
    if (extracted.had_userinfo)
        credentials[index].basic = vault.BasicRecord.init(extracted.username, extracted.password) catch return error.InvalidLegacySettings;
    count.* += 1;
    return index;
}

const Extracted = struct { clean: []const u8, username: []const u8, password: []const u8, had_userinfo: bool };
fn extractLegacyUrl(raw: []const u8, clean: []u8, username: []u8, password: []u8) !Extracted {
    const input = std.mem.trim(u8, raw, " \t\r\n");
    if (input.len == 0) return error.InvalidUrl;
    const has_scheme = std.mem.find(u8, input, "://") != null;
    const prefix = if (has_scheme) "" else "https://";
    const authority_start = if (has_scheme) (std.mem.find(u8, input, "://").? + 3) else 0;
    const authority_end = std.mem.findScalarPos(u8, input, authority_start, '/') orelse input.len;
    const authority = input[authority_start..authority_end];
    const at = std.mem.lastIndexOfScalar(u8, authority, '@');
    if (at == null) {
        const result = try std.fmt.bufPrint(clean, "{s}{s}", .{ prefix, input });
        return .{ .clean = result, .username = "", .password = "", .had_userinfo = false };
    }
    const info = authority[0..at.?];
    const colon = std.mem.findScalar(u8, info, ':');
    const encoded_user = if (colon) |i| info[0..i] else info;
    const encoded_password = if (colon) |i| info[i + 1 ..] else "";
    const decoded_user = try percentDecode(encoded_user, username);
    const decoded_password = try percentDecode(encoded_password, password);
    if (std.mem.indexOfScalar(u8, decoded_user, ':') != null) return error.InvalidUsername;
    const result = try std.fmt.bufPrint(clean, "{s}{s}{s}{s}", .{ prefix, input[0..authority_start], authority[at.? + 1 ..], input[authority_end..] });
    return .{ .clean = result, .username = decoded_user, .password = decoded_password, .had_userinfo = true };
}

fn percentDecode(input: []const u8, output: []u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(output);
    var index: usize = 0;
    while (index < input.len) {
        if (input[index] == '%') {
            if (index + 2 >= input.len) return error.InvalidEncoding;
            const byte = std.fmt.parseInt(u8, input[index + 1 .. index + 3], 16) catch return error.InvalidEncoding;
            writer.writeByte(byte) catch return error.OverBound;
            index += 3;
        } else {
            writer.writeByte(input[index]) catch return error.OverBound;
            index += 1;
        }
    }
    const decoded = writer.buffered();
    if (!std.unicode.utf8ValidateSlice(decoded)) return error.InvalidEncoding;
    return decoded;
}

fn parseFormat(value: []const u8) preferences_mod.StreamFormat {
    inline for (std.meta.tags(preferences_mod.StreamFormat)) |format| if (std.mem.eql(u8, value, @tagName(format))) return format;
    return .mp3;
}
fn validDiscordId(value: []const u8) bool {
    if (value.len == 0) return true;
    if (value.len < 17 or value.len > 20) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}
fn validText(value: []const u8, max: usize) bool {
    return value.len <= max and std.unicode.utf8ValidateSlice(value);
}
fn wipeCredentials(credentials: *[preferences_mod.max_stations]CredentialCandidate) void {
    for (credentials) |*credential| {
        if (credential.basic) |*record| record.deinit();
        if (credential.listener) |*record| record.deinit();
    }
}

test "active is first, deduped, and owns active credentials and global format" {
    const source = "{\"volume\":1.4,\"themeOverride\":\"night\",\"streamFormat\":\"flac\",\"station\":\"https://active%40user:p%C3%A4ss@RADIO.example/\",\"stationName\":\"Active\",\"stationPassword\":\"listener-secret\",\"recents\":[{\"url\":\"https://other:recent@other.example\",\"name\":\"Other\"},{\"url\":\"https://loser:old@radio.example\",\"name\":\"Duplicate\"}],\"discordEnabled\":true,\"discordClientId\":\"123456789012345678\",\"notifyTrack\":true}";
    var candidate = try parse(std.testing.allocator, source);
    defer candidate.deinit();
    try std.testing.expectEqual(@as(usize, 2), candidate.preferences.stations.len);
    try std.testing.expectEqualStrings("https://radio.example", candidate.preferences.stations[0].base);
    try std.testing.expectEqual(preferences_mod.StreamFormat.flac, candidate.preferences.stations[0].streamFormat);
    try std.testing.expectEqual(preferences_mod.StreamFormat.mp3, candidate.preferences.stations[1].streamFormat);
    try std.testing.expectEqualStrings("active@user", candidate.credentials[0].basic.?.username());
    try std.testing.expectEqualStrings("päss", candidate.credentials[0].basic.?.password());
    try std.testing.expectEqualStrings("listener-secret", candidate.credentials[0].listener.?.password());
    try std.testing.expect(candidate.preferences.discordEnabled and candidate.preferences.notifyTrack);
}

test "source is unchanged, candidate marker is incomplete, and malformed or oversized input fails" {
    var source = [_]u8{ '{', '"', 'v', 'o', 'l', 'u', 'm', 'e', '"', ':', '0', '.', '4', '}' };
    const before = source;
    var candidate = try parse(std.testing.allocator, &source);
    defer candidate.deinit();
    try std.testing.expectEqualSlices(u8, &before, &source);
    try std.testing.expect(!candidate.preferences.legacyImport.completed);
    try std.testing.expect(candidate.preferences.legacyImport.sourceDigest == null);
    try std.testing.expect(!std.mem.allEqual(u8, &candidate.source_digest, 0));
    try std.testing.expectError(error.InvalidLegacySettings, parse(std.testing.allocator, "{"));
    try std.testing.expectError(error.InvalidLegacySettings, parse(std.testing.allocator, "{\"station\":\"https://user:%ZZ@radio.example\"}"));
    try std.testing.expectError(error.InvalidLegacySettings, parse(std.testing.allocator, "{\"recents\":[{\"url\":\"javascript:alert(1)\"}]}"));
    try std.testing.expectError(error.LegacySettingsTooLarge, parse(std.testing.allocator, "x" ** (max_source_bytes + 1)));
}

test "existing secure records win and read failures never become misses" {
    try std.testing.expect(vault.importBasic(.ok, true) == .keep_secure);
    try std.testing.expect(vault.importBasic(.miss, true) == .write_legacy);
    try std.testing.expectEqual(vault.Outcome.locked, vault.importBasic(.locked, true).failed);
}

test "import preserves empty station name and never grants HTTP secret consent" {
    var candidate = try parse(std.testing.allocator, "{\"station\":\"http://user:password@radio.example/long-base-path\",\"stationName\":\"\"}");
    defer candidate.deinit();
    try std.testing.expectEqualStrings("", candidate.preferences.stations[0].name);
    try std.testing.expect(!candidate.preferences.stations[0].allowInsecureHttp);
    try std.testing.expect(candidate.credentials[0].basic != null);
}

test "legacy ambiguous Basic usernames fail before import can write a vault record" {
    try std.testing.expectError(error.InvalidLegacySettings, parse(std.testing.allocator, "{\"station\":\"https://u%3Av:p@radio.example\"}"));
}
