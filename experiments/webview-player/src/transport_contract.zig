//! Fixture-only live probe for the private SDK transport extension.
//! No bridge accepts secrets; output contains IDs/counters only.
const std = @import("std");
const sdk = @import("native_sdk");
const runner = @import("runner");
const relay_mod = @import("audio_relay.zig");
const exit_timer: u64 = 0x5452414e;

pub const panic = std.debug.FullPanic(sdk.debug.capturePanic);

const Gate = struct {
    active: u64 = 41,
    accepted: u64 = 0,
    ignored: u64 = 0,

    fn accept(self: *Gate, load_id: u64) bool {
        if (load_id == 0 or load_id != self.active) {
            self.ignored += 1;
            return false;
        }
        self.accepted += 1;
        return true;
    }
};

const Probe = struct {
    url: []const u8,
    replacement: ?[]const u8,
    authorization: ?[]const u8,
    relay: ?*relay_mod.Relay = null,
    seconds: u64 = 8,
    gate: Gate = .{},
    samples: u64 = 0,

    fn app(self: *Probe) sdk.App {
        return .{ .context = self, .name = "transport-probe", .source = sdk.WebViewSource.html("<h1>SUBWAVE transport probe</h1><p>Fixture-only native audio verification.</p>"), .start_fn = start, .event_fn = event, .stop_fn = stop };
    }

    fn load(self: *Probe, runtime: *sdk.Runtime, url: []const u8) !void {
        if (!@hasDecl(sdk.platform.PlatformServices, "audioLoadRequest")) @compileError("transport-probe requires the private player transport SDK patch");
        self.relay = try relay_mod.Relay.start(std.heap.page_allocator, .{ .upstream_url = url, .authorization = self.authorization });
        _ = try runtime.options.platform.services.audioLoadRequest(.{
            .load_id = self.gate.active,
            .url = self.relay.?.url(),
            .allow_redirects = true,
        });
        std.debug.print("{{\"event\":\"load_requested\",\"loadId\":{d}}}\n", .{self.gate.active});
    }

    fn start(context: *anyopaque, runtime: *sdk.Runtime) anyerror!void {
        const self: *Probe = @ptrCast(@alignCast(context));
        try runtime.options.platform.services.startTimer(exit_timer, self.seconds * std.time.ns_per_s, false);
        try self.load(runtime, self.url);
        if (self.replacement) |url| {
            try runtime.options.platform.services.audioStop();
            self.stopRelay();
            self.gate.active = 42;
            try self.load(runtime, url);
        }
    }

    fn event(context: *anyopaque, runtime: *sdk.Runtime, value: sdk.Event) anyerror!void {
        const self: *Probe = @ptrCast(@alignCast(context));
        switch (value) {
            .audio => |audio| {
                if (!self.gate.accept(audio.load_id)) {
                    std.debug.print("{{\"event\":\"stale_ignored\",\"loadId\":{d}}}\n", .{audio.load_id});
                    return;
                }
                if (audio.kind == .loaded) try runtime.options.platform.services.audioPlay();
                if (audio.kind == .spectrum) {
                    self.samples += 1;
                    if (self.samples % 25 != 0) return;
                }
                std.debug.print("{{\"event\":\"{s}\",\"loadId\":{d},\"samples\":{d}}}\n", .{ @tagName(audio.kind), audio.load_id, self.samples });
            },
            .timer => |timer| if (timer.id == exit_timer) {
                try runtime.options.platform.services.quitApp();
            },
            else => {},
        }
    }

    fn stopRelay(self: *Probe) void {
        if (self.relay) |relay| relay.stop();
        self.relay = null;
    }

    fn stop(context: *anyopaque, runtime: *sdk.Runtime) anyerror!void {
        const self: *Probe = @ptrCast(@alignCast(context));
        defer self.stopRelay();
        try runtime.options.platform.services.audioStop();
        std.debug.print("{{\"event\":\"shutdown\",\"samples\":{d},\"ignored\":{d}}}\n", .{ self.samples, self.gate.ignored });
    }
};

fn loopback(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (!std.mem.eql(u8, uri.scheme, "http") or uri.port == null or uri.user != null or uri.password != null) return false;
    const host = uri.host orelse return false;
    const raw = switch (host) {
        .raw => |v| v,
        .percent_encoded => |v| v,
    };
    return std.mem.eql(u8, raw, "127.0.0.1") or std.mem.eql(u8, raw, "::1") or std.mem.eql(u8, raw, "[::1]");
}

pub fn main(init: std.process.Init) !void {
    const url = init.environ_map.get("SUBWAVE_TRANSPORT_URL") orelse return error.MissingFixtureUrl;
    const replacement = init.environ_map.get("SUBWAVE_TRANSPORT_REPLACE_URL");
    if (!loopback(url)) return error.NonLoopbackFixtureUrl;
    if (replacement) |next| if (!loopback(next)) return error.NonLoopbackFixtureUrl;
    const seconds = try std.fmt.parseInt(u64, init.environ_map.get("SUBWAVE_TRANSPORT_SECONDS") orelse "8", 10);
    if (seconds == 0 or seconds > 60) return error.InvalidProbeDuration;
    var probe = Probe{ .url = url, .replacement = replacement, .authorization = init.environ_map.get("SUBWAVE_TRANSPORT_AUTHORIZATION"), .seconds = seconds };
    defer probe.stopRelay();
    try runner.runWithOptions(probe.app(), .{ .app_name = "SUBWAVE Transport Probe", .window_title = "SUBWAVE Transport Probe", .bundle_id = "dev.subwave.player.transportprobe" }, init);
}

test "old native load events never become current on receipt" {
    var gate = Gate{};
    try std.testing.expect(gate.accept(41));
    gate.active = 42;
    for (0..5) |_| try std.testing.expect(!gate.accept(41));
    try std.testing.expect(!gate.accept(0));
    try std.testing.expect(gate.accept(42));
    try std.testing.expectEqual(@as(u64, 6), gate.ignored);
}

test "probe accepts only literal HTTP loopback fixture addresses" {
    try std.testing.expect(loopback("http://127.0.0.1:43127/stream.mp3"));
    try std.testing.expect(loopback("http://[::1]:43127/stream.mp3"));
    try std.testing.expect(!loopback("http://localhost:43127/stream.mp3"));
    try std.testing.expect(!loopback("http://%31%32%37.0.0.1:43127/stream.mp3"));
    try std.testing.expect(!loopback("http://user:pass@127.0.0.1:43127/stream.mp3"));
    try std.testing.expect(!loopback("http://127.0.0.1.example:43127/stream.mp3"));
}

test {
    _ = relay_mod;
}
