//! Available-host runtime exercise of the public station session integration.
const std = @import("std");
const sdk = @import("native_sdk");
const runner = @import("runner");
const host_mod = @import("session_host.zig");
const identity = @import("station_identity.zig");
pub const panic = std.debug.FullPanic(sdk.debug.capturePanic);
const exit_timer: u64 = 0x2000_0000;
const switch_timer: u64 = exit_timer + 1;
const Probe = struct {
    host: host_mod.Host,
    io: std.Io,
    address: []const u8,
    replacement: ?[]const u8,
    last_revision: u64 = 0,
    logged_spectrum: u64 = 0,
    fn now(self: *Probe) u64 {
        return @intCast(@max(0, std.Io.Clock.awake.now(self.io).toMilliseconds()));
    }
    fn app(self: *Probe) sdk.App {
        return .{ .context = self, .name = "session-probe", .source = sdk.WebViewSource.html("<h1>SUBWAVE station session probe</h1>"), .start_fn = start, .event_fn = event, .stop_fn = stop };
    }
    fn start(context: *anyopaque, runtime: *sdk.Runtime) !void {
        const self: *Probe = @ptrCast(@alignCast(context));
        try self.host.bind(runtime);
        _ = try self.host.connectPublic(self.address);
        try runtime.options.platform.services.startTimer(exit_timer, 12 * std.time.ns_per_s, false);
        if (self.replacement != null) try runtime.options.platform.services.startTimer(switch_timer, 4 * std.time.ns_per_s, false);
    }
    fn event(context: *anyopaque, runtime: *sdk.Runtime, value: sdk.Event) !void {
        const self: *Probe = @ptrCast(@alignCast(context));
        const services = runtime.options.platform.services;
        const now_ms = self.now();
        try self.host.drain(services, now_ms);
        switch (value) {
            .audio => |audio| try self.host.onAudio(services, audio, now_ms),
            .timer => |timer| if (timer.id == exit_timer) {
                try services.quitApp();
            } else if (timer.id == switch_timer) {
                _ = try self.host.connectPublic(self.replacement.?);
            } else try self.host.onTimer(services, timer.id, now_ms),
            else => {},
        }
        if (self.last_revision != self.host.revision) {
            self.last_revision = self.host.revision;
            std.debug.print("{{\"event\":\"state\",\"generation\":{d},\"loadId\":{d},\"loads\":{d},\"playback\":\"{s}\",\"attempt\":{d}}}\n", .{ self.host.session.generation, self.host.session.load_id orelse 0, self.host.audio.loads, @tagName(self.host.session.playback), self.host.recovery.attempt });
        }
        if (self.host.spectrum_sequence >= self.logged_spectrum + 25) {
            self.logged_spectrum = self.host.spectrum_sequence;
            std.debug.print("{{\"event\":\"spectrum\",\"generation\":{d},\"loadId\":{d},\"samples\":{d}}}\n", .{ self.host.session.generation, self.host.session.load_id orelse 0, self.logged_spectrum });
        }
    }
    fn stop(context: *anyopaque, runtime: *sdk.Runtime) !void {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.host.stop(runtime.options.platform.services);
        std.debug.print("{{\"event\":\"shutdown\",\"generation\":{d},\"loads\":{d},\"samples\":{d}}}\n", .{ self.host.session.generation, self.host.audio.loads, self.host.spectrum_sequence });
    }
};
fn validate(address: []const u8) !void {
    var station: identity.StationIdentity = .{};
    _ = try identity.normalizeStation(address, &station);
    if (!std.mem.startsWith(u8, station.base(), "http://127.0.0.1:")) return error.NonLoopbackFixture;
    const uri = try std.Uri.parse(station.base());
    if (uri.port == null or !std.mem.eql(u8, uri.path.percent_encoded, "")) return error.NonLoopbackFixture;
}
pub fn main(init: std.process.Init) !void {
    const address = init.environ_map.get("SUBWAVE_SESSION_FIXTURE") orelse return error.MissingFixture;
    const replacement = init.environ_map.get("SUBWAVE_SESSION_REPLACEMENT");
    try validate(address);
    if (replacement) |value| try validate(value);
    var probe: Probe = .{ .host = try host_mod.Host.init(std.heap.page_allocator), .io = init.io, .address = address, .replacement = replacement };
    defer probe.host.deinit();
    try runner.runWithOptions(probe.app(), .{ .app_name = "SUBWAVE Session Probe", .window_title = "SUBWAVE Session Probe", .bundle_id = "dev.subwave.player.sessionprobe" }, init);
    if (probe.host.spectrum_sequence == 0 or probe.host.session.generation != @as(u64, if (replacement != null) 2 else 1)) return error.SessionProofFailed;
}
