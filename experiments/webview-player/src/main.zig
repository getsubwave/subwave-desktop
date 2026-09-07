const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const protocol = @import("protocol.zig");
const player_host = @import("player_host.zig");
const view_delivery = @import("view_delivery.zig");
const build_options = @import("build_options");
const builtin = @import("builtin");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const names = [_][]const u8{ "subwave.proof.snapshot", "subwave.proof.command", "subwave.proof.window", "subwave.proof.spectrumAck", "subwave.proof.diagnostics" };
const production_origins = [_][]const u8{ "zero://app", "http://127.0.0.1:5173" };
const automation_origins = [_][]const u8{ "zero://app", "http://127.0.0.1:5173", "zero://inline" };

fn allowedOrigins() []const []const u8 {
    return if (build_options.automation) &automation_origins else &production_origins;
}

const App = struct {
    env_map: *std.process.Environ.Map,
    io: std.Io,
    runtime: ?*native_sdk.Runtime = null,
    player: player_host.PlayerHost = .{},
    delivery: view_delivery.ViewDelivery = .{},
    stream_url: []const u8 = "",
    mini_id: ?native_sdk.WindowId = null,
    main_visible: bool = true,
    mini_visible: bool = false,
    mini_source_store: [4096]u8 = undefined,
    frontend_root_store: [std.Io.Dir.max_path_bytes]u8 = undefined,
    policies: [names.len]native_sdk.bridge.CommandPolicy = undefined,
    handlers: [names.len]native_sdk.bridge.Handler = undefined,

    fn init(env_map: *std.process.Environ.Map, io: std.Io) !App {
        var self: App = .{ .env_map = env_map, .io = io };
        self.stream_url = env_map.get("SUBWAVE_PROOF_STREAM_URL") orelse "";
        if (self.stream_url.len > 0 and !isLoopbackStream(self.stream_url)) return error.NonLoopbackProofStream;
        for (names, 0..) |name, index| self.policies[index] = .{ .name = name, .origins = allowedOrigins() };
        self.handlers = .{
            .{ .name = names[0], .context = &self, .invoke_fn = snapshotHandler },
            .{ .name = names[1], .context = &self, .invoke_fn = commandHandler },
            .{ .name = names[2], .context = &self, .invoke_fn = windowHandler },
            .{ .name = names[3], .context = &self, .invoke_fn = spectrumAckHandler },
            .{ .name = names[4], .context = &self, .invoke_fn = diagnosticsHandler },
        };
        return self;
    }

    fn app(self: *App) native_sdk.App {
        return .{ .context = self, .name = "webview-player", .source = native_sdk.frontend.productionSource(.{ .dist = "frontend/dist" }), .source_fn = source, .start_fn = start, .event_fn = event, .stop_fn = stop };
    }

    fn bridge(self: *App) native_sdk.BridgeDispatcher {
        for (&self.handlers) |*handler| handler.context = self;
        return .{ .policy = .{ .enabled = true, .commands = &self.policies }, .registry = .{ .handlers = &self.handlers } };
    }

    fn source(context: *anyopaque) anyerror!native_sdk.WebViewSource {
        const self: *App = @ptrCast(@alignCast(context));
        return self.frontendSource("index.html");
    }
    fn start(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        self.runtime = runtime;
    }
    fn stop(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        runtime.options.platform.services.audioStop() catch {};
        self.runtime = null;
    }
    fn event(context: *anyopaque, runtime: *native_sdk.Runtime, value: native_sdk.Event) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        switch (value) {
            .audio => |audio| if (audio.kind == .spectrum) {
                _ = try self.player.onAudio(runtime.options.platform.services, audio);
                if (self.player.acceptSpectrum()) self.delivery.offerSpectrum(runtime, self.player.generation, audio.bands);
            } else if (try self.player.onAudio(runtime.options.platform.services, audio)) self.pushSnapshot(),
            .window_closed => |closed| if (self.mini_id == closed.window_id) {
                self.delivery.forget(closed.window_id);
                self.mini_id = null;
                self.mini_visible = false;
                if (!self.main_visible) {
                    runtime.showWindow(1) catch return;
                    self.delivery.setVisible(1, true);
                    self.main_visible = true;
                    self.pushSnapshot();
                }
            },
            else => {},
        }
    }

    fn snapshotHandler(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *App = @ptrCast(@alignCast(context));
        if (!emptyObject(invocation.request.payload)) return invalid(output);
        self.delivery.ready(invocation.source.window_id, self.player.revision);
        return protocol.writeSnapshot(self.player.snapshot(), output);
    }
    fn commandHandler(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *App = @ptrCast(@alignCast(context));
        const command = protocol.parseCommand(invocation.request.payload) catch return invalid(output);
        if (command == .play and self.stream_url.len == 0) return self.failed(output);
        const runtime = self.runtime orelse return self.failed(output);
        self.player.apply(runtime.options.platform.services, command, self.stream_url) catch return self.failed(output);
        if (command == .stop) self.delivery.clearPending();
        self.pushSnapshot();
        return self.success(output);
    }
    fn windowHandler(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *App = @ptrCast(@alignCast(context));
        const action = protocol.parseWindowAction(invocation.request.payload) catch return invalid(output);
        const runtime = self.runtime orelse return self.failed(output);
        switch (action) {
            .openMini => if (self.mini_id) |id| {
                runtime.focusWindow(id) catch return self.failed(output);
                self.delivery.setVisible(id, true);
                self.mini_visible = true;
            } else {
                const info = runtime.createWindow(.{ .label = "mini", .title = "SUBWAVE Mini Proof", .default_frame = native_sdk.geometry.RectF.init(80, 80, 380, 210), .min_width = 320, .min_height = 180, .source = try self.miniSource() }) catch return self.failed(output);
                self.mini_id = info.id;
                self.mini_visible = true;
                self.delivery.setVisible(info.id, true);
            },
            .closeMini => if (self.mini_id) |id| {
                if (!self.main_visible) {
                    runtime.showWindow(1) catch return self.failed(output);
                    self.delivery.setVisible(1, true);
                    self.main_visible = true;
                    self.pushSnapshot();
                }
                runtime.closeWindow(id) catch return self.failed(output);
                self.delivery.forget(id);
                self.mini_id = null;
                self.mini_visible = false;
            },
            .hideMain => {
                if (self.mini_id == null) return self.failed(output);
                runtime.hideWindow(1) catch return self.failed(output);
                self.delivery.setVisible(1, false);
                self.main_visible = false;
            },
            .showMain => {
                runtime.showWindow(1) catch return self.failed(output);
                self.delivery.setVisible(1, true);
                self.main_visible = true;
                self.pushSnapshot();
            },
        }
        return self.success(output);
    }
    fn spectrumAckHandler(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *App = @ptrCast(@alignCast(context));
        const sequence = protocol.parseSpectrumAck(invocation.request.payload) catch return invalid(output);
        const runtime = self.runtime orelse return self.failed(output);
        if (!self.delivery.acknowledge(runtime, invocation.source.window_id, self.player.generation, sequence)) return invalid(output);
        return std.fmt.bufPrint(output, "{{\"ok\":true}}", .{});
    }
    fn diagnosticsHandler(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *App = @ptrCast(@alignCast(context));
        if (!emptyObject(invocation.request.payload)) return invalid(output);
        const first = self.delivery.diagnostic(0);
        const second = self.delivery.diagnostic(1);
        return std.fmt.bufPrint(output, "{{\"loadCount\":{d},\"playCount\":{d},\"spectrumReceived\":{d},\"spectrumDelivered\":{d},\"spectrumAcked\":{d},\"maxPendingPerView\":{d},\"mainVisible\":{},\"miniVisible\":{},\"views\":[{{\"windowId\":{d},\"ready\":{},\"visible\":{},\"awaitingAck\":{},\"deliveredSequence\":{d},\"pendingSequence\":{d},\"snapshotCount\":{d},\"lastSnapshotRevision\":{d}}},{{\"windowId\":{d},\"ready\":{},\"visible\":{},\"awaitingAck\":{},\"deliveredSequence\":{d},\"pendingSequence\":{d},\"snapshotCount\":{d},\"lastSnapshotRevision\":{d}}}]}}", .{ self.player.load_count, self.player.play_count, self.delivery.sample_received, self.delivery.sample_delivered, self.delivery.ack_count, self.delivery.max_pending_per_view, self.main_visible, self.mini_visible, first.window_id, first.ready, first.visible, first.awaiting_ack, first.delivered_sequence, first.pending_sequence, first.snapshot_count, first.last_snapshot_revision, second.window_id, second.ready, second.visible, second.awaiting_ack, second.delivered_sequence, second.pending_sequence, second.snapshot_count, second.last_snapshot_revision });
    }
    fn pushSnapshot(self: *App) void {
        const runtime = self.runtime orelse return;
        var buffer: [512]u8 = undefined;
        const json = protocol.writeSnapshot(self.player.snapshot(), &buffer) catch return;
        self.delivery.pushSnapshot(runtime, json, self.player.revision);
    }
    fn success(self: *App, output: []u8) ![]const u8 {
        var buffer: [512]u8 = undefined;
        const snapshot = try protocol.writeSnapshot(self.player.snapshot(), &buffer);
        return std.fmt.bufPrint(output, "{{\"ok\":true,\"snapshot\":{s}}}", .{snapshot});
    }
    fn failed(self: *App, output: []u8) ![]const u8 {
        _ = self;
        return std.fmt.bufPrint(output, "{{\"ok\":false,\"error\":\"failed\"}}", .{});
    }
    fn miniSource(self: *App) !native_sdk.WebViewSource {
        if (self.env_map.get("NATIVE_SDK_FRONTEND_URL")) |url| {
            const joined = try std.fmt.bufPrint(&self.mini_source_store, "{s}{s}view=mini", .{ url, if (std.mem.indexOfScalar(u8, url, '?') == null) "?" else "&" });
            return native_sdk.WebViewSource.url(joined);
        }
        // A plain zero:// URL does not install an asset root for a newly
        // created WebView. Keep this an asset source so the second window
        // owns its resolver; Linux preserves the query on the entry URL
        // while resolving the file path without it.
        return self.frontendSource("index.html?view=mini");
    }

    fn frontendSource(self: *App, entry: []const u8) !native_sdk.WebViewSource {
        if (self.env_map.get("NATIVE_SDK_FRONTEND_URL")) |url| {
            if (url.len > 0) return native_sdk.WebViewSource.url(url);
        }
        const root = resolveFrontendRoot(self.io, &self.frontend_root_store);
        return native_sdk.WebViewSource.assets(.{ .root_path = root, .entry = entry, .origin = "zero://app", .spa_fallback = true });
    }
};

fn resolveFrontendRoot(io: std.Io, output: []u8) []const u8 {
    var executable_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const executable_len = std.process.executablePath(io, &executable_buffer) catch return "frontend/dist";
    const candidate = packagedFrontendRoot(executable_buffer[0..executable_len], output) catch return "frontend/dist";
    var index_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const index_path = std.fmt.bufPrint(&index_buffer, "{s}/index.html", .{candidate}) catch return "frontend/dist";
    var file = std.Io.Dir.cwd().openFile(io, index_path, .{}) catch return "frontend/dist";
    file.close(io);
    return candidate;
}

fn packagedFrontendRoot(executable_path: []const u8, output: []u8) ![]const u8 {
    const executable_dir = std.fs.path.dirname(executable_path) orelse return error.InvalidExecutablePath;
    const resources = if (builtin.os.tag == .macos) "Resources" else "resources";
    return std.fmt.bufPrint(output, "{s}/../{s}/frontend/dist", .{ executable_dir, resources });
}

fn emptyObject(payload: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, payload, " \t\r\n"), "{}");
}
fn invalid(output: []u8) ![]const u8 {
    return std.fmt.bufPrint(output, "{{\"ok\":false,\"error\":\"invalid_request\"}}", .{});
}
fn isLoopbackStream(url: []const u8) bool {
    if (url.len == 0 or url.len > 4096) return false;
    const uri = std.Uri.parse(url) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") or uri.user != null or uri.password != null or uri.port == null) return false;
    const host = uri.host orelse return false;
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const raw = host.toRaw(&host_buffer) catch return false;
    return std.mem.eql(u8, raw, "127.0.0.1") or std.mem.eql(u8, raw, "::1") or std.mem.eql(u8, raw, "[::1]");
}

pub fn main(init_value: std.process.Init) !void {
    var state = try App.init(init_value.environ_map, init_value.io);
    try runner.runWithOptions(state.app(), .{ .app_name = "SUBWAVE WebView Proof", .window_title = "SUBWAVE WebView Proof", .bundle_id = "dev.subwave.player.webviewproof", .icon_path = "assets/icon.png", .bridge = state.bridge(), .security = .{ .navigation = .{ .allowed_origins = allowedOrigins() } }, .js_window_api = true }, init_value);
}

test "proof stream accepts loopback only" {
    try std.testing.expect(isLoopbackStream("http://127.0.0.1:45601/stream.mp3"));
    try std.testing.expect(isLoopbackStream("http://[::1]:45601/stream.mp3"));
    try std.testing.expect(!isLoopbackStream("http://localhost:45601/stream.mp3"));
    try std.testing.expect(!isLoopbackStream("http://127.0.0.1.example:45601/stream.mp3"));
    try std.testing.expect(!isLoopbackStream("http://127.0.0.2:45601/stream.mp3"));
    try std.testing.expect(!isLoopbackStream("http://127.0.0.1:80@evil.example/stream.mp3"));
    try std.testing.expect(!isLoopbackStream("https://radio.example/stream.mp3"));
}
test "packaged mini owns an asset resolver and route query" {
    var buffer: [256]u8 = undefined;
    const root = try packagedFrontendRoot("/opt/subwave/bin/webview-player", &buffer);
    if (builtin.os.tag == .macos) {
        try std.testing.expectEqualStrings("/opt/subwave/bin/../Resources/frontend/dist", root);
    } else {
        try std.testing.expectEqualStrings("/opt/subwave/bin/../resources/frontend/dist", root);
    }
}
test {
    _ = protocol;
    _ = @import("player_host.zig");
    _ = @import("view_delivery.zig");
}
