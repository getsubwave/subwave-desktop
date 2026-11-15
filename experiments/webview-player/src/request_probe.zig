//! Real runtime wake/drain proof against a literal-loopback fixture only.
const std = @import("std");
const sdk = @import("native_sdk");
const runner = @import("runner");
const effects = @import("host_effects.zig");
const identity = @import("station_identity.zig");
const selection = @import("station_selection.zig");
const end_timer: u64 = 0x48545450;
pub const panic = std.debug.FullPanic(sdk.debug.capturePanic);

const Probe = struct {
    owner: effects.Owner,
    station: identity.StationIdentity,
    coordinator: selection.Coordinator = .{},
    responses: usize = 0,
    failed: bool = false,

    fn app(self: *Probe) sdk.App {
        return .{ .context = self, .name = "request-probe", .source = sdk.WebViewSource.html("<h1>SUBWAVE request probe</h1><p>Native asynchronous fixture requests.</p>"), .start_fn = start, .event_fn = event, .stop_fn = stop };
    }

    fn start(context: *anyopaque, runtime: *sdk.Runtime) !void {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.owner.bind(runtime);
        try runtime.options.platform.services.startTimer(end_timer, 8 * std.time.ns_per_s, false);
        const begun = try self.coordinator.begin(self.station.base());
        const request = try self.owner.request(&begun.station, begun.operation_id, begun.generation, .health, .{}, null);
        try self.coordinator.attachRequest(begun.operation_id, request);
    }

    fn event(context: *anyopaque, runtime: *sdk.Runtime, incoming: sdk.Event) !void {
        const self: *Probe = @ptrCast(@alignCast(context));
        var boundary = self.owner.boundary();
        while (self.owner.next(&boundary)) |value| {
            var completion = value;
            defer completion.deinit();
            self.responses += 1;
            std.debug.print("{{\"completionBoundary\":\"{s}\"}}\n", .{@tagName(incoming)});
            switch (completion.result) {
                .failure => |failure| {
                    if (completion.tag.kind == .health) _ = self.coordinator.resolve(completion.tag, .{ .failed = .health_failed });
                    self.failed = true;
                    std.debug.print("{{\"endpoint\":\"{s}\",\"error\":\"{s}\"}}\n", .{ @tagName(completion.tag.kind), @tagName(failure) });
                },
                .data => |data| {
                    std.debug.print("{{\"endpoint\":\"{s}\",\"status\":{d}}}\n", .{ @tagName(completion.tag.kind), completion.status });
                    if (completion.tag.kind == .health) {
                        if (!data.payload.health.isHealthy()) return error.InvalidHealth;
                        const activated = self.coordinator.resolve(completion.tag, .healthy).activated;
                        self.owner.cancelGeneration(activated.old_generation);
                        self.station = activated.new_station;
                        std.debug.print("{{\"activation\":{d}}}\n", .{activated.new_generation});
                        _ = try self.owner.request(&self.station, 1, 1, .now_playing, .{}, null);
                        _ = try self.owner.request(&self.station, 1, 1, .state, .{}, null);
                    }
                },
            }
        }
        if (self.responses == 3 or self.failed) try runtime.options.platform.services.quitApp();
        switch (incoming) {
            .timer => |timer| if (timer.id == end_timer) {
                self.failed = true;
                try runtime.options.platform.services.quitApp();
            },
            else => {},
        }
    }

    fn stop(context: *anyopaque, _: *sdk.Runtime) !void {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.owner.stop();
    }
};

pub fn main(init: std.process.Init) !void {
    var station: identity.StationIdentity = .{};
    _ = try identity.normalizeStation(init.environ_map.get("SUBWAVE_REQUEST_FIXTURE") orelse return error.MissingFixture, &station);
    const uri = try std.Uri.parse(station.base());
    const host = uri.host orelse return error.NonLoopbackFixture;
    const host_text = switch (host) {
        .raw, .percent_encoded => |value| value,
    };
    if (!std.mem.eql(u8, host_text, "127.0.0.1") or uri.port == null or !std.mem.eql(u8, uri.scheme, "http"))
        return error.NonLoopbackFixture;
    var probe: Probe = .{ .owner = try effects.Owner.init(init.gpa), .station = station };
    defer probe.owner.deinit();
    try runner.runWithOptions(probe.app(), .{ .app_name = "SUBWAVE Request Probe", .window_title = "SUBWAVE Request Probe", .bundle_id = "dev.subwave.player.requestprobe" }, init);
    if (probe.failed or probe.responses != 3 or probe.coordinator.active_station == null or probe.coordinator.generation != 1) return error.RequestProbeFailed;
}
