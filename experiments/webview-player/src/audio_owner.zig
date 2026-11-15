//! Exactly one relay/native decoder pair. Native callbacks retain their source
//! load ID; session policy decides whether an event is still current.
const std = @import("std");
const sdk = @import("native_sdk");
const relay_mod = @import("audio_relay.zig");

pub const Owner = struct {
    allocator: std.mem.Allocator,
    relay: ?*relay_mod.Relay = null,
    load_id: u64 = 0,
    loads: u64 = 0,
    plays: u64 = 0,

    pub fn load(self: *Owner, services: sdk.platform.PlatformServices, load_id: u64, options: relay_mod.Options) !void {
        if (load_id == 0) return error.InvalidLoadIdentity;
        try self.stop(services);
        const relay = try relay_mod.Relay.start(self.allocator, options);
        errdefer relay.stop();
        _ = services.audioLoadRequest(.{ .load_id = load_id, .url = relay.url(), .allow_redirects = true }) catch |err| {
            // Backends may have partially allocated a decoder before failing.
            services.audioStop() catch {};
            return err;
        };
        self.relay = relay;
        self.load_id = load_id;
        self.loads += 1;
    }

    pub fn play(self: *Owner, services: sdk.platform.PlatformServices) !void {
        if (self.load_id == 0) return error.NoActiveLoad;
        try services.audioPlay();
        self.plays += 1;
    }

    pub fn pause(self: *Owner, services: sdk.platform.PlatformServices) !void {
        if (self.load_id == 0) return;
        try services.audioPause();
    }

    pub fn stop(self: *Owner, services: sdk.platform.PlatformServices) !void {
        self.load_id = 0;
        defer {
            if (self.relay) |relay| relay.stop();
            self.relay = null;
        }
        try services.audioStop();
    }
};

const Fake = struct {
    last_load: u64 = 0,
    fail_load: bool = false,
    fail_stop: bool = false,
    fn services(self: *Fake) sdk.platform.PlatformServices {
        return .{ .context = self, .audio_load_request_fn = load, .audio_stop_fn = stop };
    }
    fn load(context: ?*anyopaque, request: sdk.platform.AudioUrlRequest) !sdk.platform.AudioLoadResolution {
        const self: *Fake = @ptrCast(@alignCast(context.?));
        try std.testing.expect(request.headers.len == 0 and request.allow_redirects);
        try std.testing.expect(std.mem.startsWith(u8, request.url, "http://127.0.0.1:"));
        try std.testing.expect(std.mem.indexOf(u8, request.url, "sentinel") == null);
        if (self.fail_load) return error.DecoderFailed;
        self.last_load = request.load_id;
        return .stream;
    }
    fn stop(context: ?*anyopaque) !void {
        const self: *Fake = @ptrCast(@alignCast(context.?));
        if (self.fail_stop) return error.StopFailed;
    }
};

test "relay replacement carries only native load identity and cleans failed loads" {
    var fake: Fake = .{};
    var owner: Owner = .{ .allocator = std.testing.allocator };
    defer owner.stop(fake.services()) catch {};
    const options: relay_mod.Options = .{ .upstream_url = "http://127.0.0.1:1/stream.mp3?auth=sentinel", .authorization = "Basic sentinel" };
    try owner.load(fake.services(), 41, options);
    try owner.load(fake.services(), 42, options);
    try std.testing.expectEqual(@as(u64, 42), fake.last_load);
    try std.testing.expectEqual(@as(u64, 2), owner.loads);
    fake.fail_load = true;
    try std.testing.expectError(error.DecoderFailed, owner.load(fake.services(), 43, options));
    try std.testing.expect(owner.relay == null and owner.load_id == 0);
}

test "relay cancellation still completes when native stop fails" {
    var fake: Fake = .{};
    var owner: Owner = .{ .allocator = std.testing.allocator };
    try owner.load(fake.services(), 1, .{ .upstream_url = "http://127.0.0.1:1/stream.mp3" });
    fake.fail_stop = true;
    try std.testing.expectError(error.StopFailed, owner.stop(fake.services()));
    try std.testing.expect(owner.relay == null and owner.load_id == 0);
}
