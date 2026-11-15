//! The closed station API address/header boundary. No arbitrary bridge fetch.
const std = @import("std");
const identity = @import("station_identity.zig");
pub const Endpoint = @import("station_decoders.zig").Endpoint;

pub const Auth = struct {
    authorization: ?[]const u8 = null,
    allow_insecure_http: bool = false,
};

pub fn path(endpoint: Endpoint) []const u8 {
    return switch (endpoint) {
        .health => "/api/health",
        .now_playing => "/api/now-playing",
        .state => "/api/state",
        .themes => "/api/themes",
        .session => "/api/session",
        .schedule => "/api/schedule",
        .station_auth => "/api/station-auth",
    };
}

pub fn url(station: *const identity.StationIdentity, endpoint: Endpoint, output: []u8) ![]const u8 {
    return std.fmt.bufPrint(output, "{s}{s}", .{ station.base(), path(endpoint) });
}

/// Returned headers borrow host credential memory only until Effects.fetch
/// copies them synchronously. They are never part of a completion/snapshot.
pub fn headers(station: *const identity.StationIdentity, auth: Auth, output: *[2]std.http.Header) ![]const std.http.Header {
    if (auth.authorization != null and
        std.mem.startsWith(u8, station.base(), "http://") and !auth.allow_insecure_http)
        return error.InsecureCredentials;
    var count: usize = 0;
    if (auth.authorization) |value| {
        try validHeader(value);
        if (!std.mem.startsWith(u8, value, "Basic ")) return error.InvalidAuthorization;
        output[count] = .{ .name = "Authorization", .value = value };
        count += 1;
    }
    return output[0..count];
}

fn validHeader(value: []const u8) !void {
    if (value.len == 0 or value.len > 4096 or std.mem.findAny(u8, value, "\r\n\x00") != null)
        return error.InvalidAuthorization;
}

test "closed endpoints preserve canonical base path and require consent for secrets" {
    var station: identity.StationIdentity = .{};
    _ = try identity.normalizeStation("http://127.0.0.1:43127/player/", &station);
    var store: [512]u8 = undefined;
    try std.testing.expectEqualStrings("http://127.0.0.1:43127/player/api/now-playing", try url(&station, .now_playing, &store));
    var hs: [2]std.http.Header = undefined;
    try std.testing.expectError(error.InsecureCredentials, headers(&station, .{ .authorization = "Basic sentinel" }, &hs));
    const allowed = try headers(&station, .{ .authorization = "Basic sentinel", .allow_insecure_http = true }, &hs);
    try std.testing.expectEqual(@as(usize, 1), allowed.len);
    try std.testing.expectEqualStrings("Authorization", allowed[0].name);
    try std.testing.expectError(error.InvalidAuthorization, headers(&station, .{ .authorization = "Basic a\nb", .allow_insecure_http = true }, &hs));
    try std.testing.expectEqual(@as(usize, 0), (try headers(&station, .{}, &hs)).len);
}
