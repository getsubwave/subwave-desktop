const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const protocol = @import("protocol.zig");
const model_mod = @import("foundation_model.zig");
const station_protocol = @import("station_protocol.zig");
const automation_vault = @import("automation_vault.zig");
const view_delivery = @import("view_delivery.zig");
const build_options = @import("build_options");
const builtin = @import("builtin");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const names = [_][]const u8{
    "subwave.player.snapshot",           "subwave.player.station.connect",          "subwave.player.station.cancel",
    "subwave.player.station.forget",     "subwave.player.station.disconnect",       "subwave.player.playback.command",
    "subwave.player.preferences.update", "subwave.player.preferences.importLegacy", "subwave.proof.window",
    "subwave.proof.spectrumAck",         "subwave.proof.diagnostics",
};
const production_origins = [_][]const u8{"zero://app"};
const development_origins = [_][]const u8{ "zero://app", "http://127.0.0.1:5173" };
const automation_origins = [_][]const u8{ "zero://app", "zero://inline" };
const automation_development_origins = [_][]const u8{ "zero://app", "zero://inline", "http://127.0.0.1:5173" };

fn allowedOrigins() []const []const u8 {
    return originsFor(build_options.automation, build_options.frontend_dev);
}

fn originsFor(automation: bool, development: bool) []const []const u8 {
    return if (automation and development) &automation_development_origins else if (automation) &automation_origins else if (development) &development_origins else &production_origins;
}

const App = struct {
    env_map: *std.process.Environ.Map,
    io: std.Io,
    runtime: ?*native_sdk.Runtime = null,
    model: *model_mod.Model,
    last_spectrum_sequence: u64 = 0,
    last_audio_load: ?u64 = null,
    test_vault: ?*automation_vault.Vault = null,
    test_vault_services: native_sdk.platform.PlatformServices = .{},
    delivery: view_delivery.ViewDelivery = .{},
    mini_id: ?native_sdk.WindowId = null,
    main_visible: bool = true,
    mini_visible: bool = false,
    mini_source_store: [4096]u8 = undefined,
    frontend_root_store: [std.Io.Dir.max_path_bytes]u8 = undefined,
    policies: [names.len]native_sdk.bridge.CommandPolicy = undefined,
    handlers: [names.len]native_sdk.bridge.Handler = undefined,

    fn init(env_map: *std.process.Environ.Map, io: std.Io) !App {
        if (env_map.get("NATIVE_SDK_FRONTEND_URL")) |url| {
            if (!build_options.frontend_dev or (!std.mem.eql(u8, url, "http://127.0.0.1:5173") and !std.mem.eql(u8, url, "http://127.0.0.1:5173/"))) return error.UnapprovedFrontendOrigin;
        }
        const model = try std.heap.page_allocator.create(model_mod.Model);
        errdefer std.heap.page_allocator.destroy(model);
        model.* = try model_mod.Model.init(std.heap.page_allocator, env_map);
        var self: App = .{ .env_map = env_map, .io = io, .model = model };
        for (names, 0..) |name, index| {
            self.policies[index] = .{ .name = name, .origins = allowedOrigins() };
            self.handlers[index] = .{ .name = name, .context = &self, .invoke_fn = switch (index) {
                0 => snapshotHandler,
                8 => windowHandler,
                9 => spectrumAckHandler,
                10 => diagnosticsHandler,
                else => commandHandler,
            } };
        }
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
        return self.frontendSource("index.html?foundation=1");
    }
    fn start(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        self.runtime = runtime;
        errdefer {
            self.model.stop(runtime.options.platform.services);
            if (self.test_vault) |vault| vault.deinit();
            self.test_vault = null;
            self.runtime = null;
        }
        if (comptime build_options.automation) {
            if (self.env_map.get("SUBWAVE_TEST_VAULT_DIR")) |path| {
                if (!std.mem.startsWith(u8, path, "/tmp/subwave-foundation-") or std.mem.indexOf(u8, path, "/../") != null or std.mem.endsWith(u8, path, "/..")) return error.UnapprovedAutomationVault;
                self.test_vault = try automation_vault.Vault.init(std.heap.page_allocator, self.io, path);
                self.test_vault_services = self.test_vault.?.services();
                self.model.host.http.effects.bindCredentialsStore(.{ .services = &self.test_vault_services, .service = "dev.subwave.player.webviewproof", .permitted = true });
            }
        }
        // Effects binds a credential store once. Install the synthetic store
        // before Host.bind can bind the platform store.
        try self.model.start(runtime, self.now());
    }
    fn stop(context: *anyopaque, runtime: *native_sdk.Runtime) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        self.model.stop(runtime.options.platform.services);
        if (self.test_vault) |vault| vault.deinit();
        self.test_vault = null;
        self.runtime = null;
    }
    fn event(context: *anyopaque, runtime: *native_sdk.Runtime, value: native_sdk.Event) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        try self.model.drain(runtime.options.platform.services, self.now());
        switch (value) {
            .audio => |audio| try self.model.onAudio(runtime.options.platform.services, audio, self.now()),
            .timer => |timer| try self.model.onTimer(runtime.options.platform.services, timer.id, self.now()),
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
        self.flush();
    }

    fn snapshotHandler(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *App = @ptrCast(@alignCast(context));
        if (!emptyObject(invocation.request.payload)) return invalid(output);
        const initialize_view = !std.mem.eql(u8, invocation.source.origin, "zero://inline");
        if (initialize_view) self.delivery.ready(invocation.source.window_id, self.model.host.revision);
        const result = try station_protocol.writeSnapshot(self.model.snapshot(self.now()), output);
        // Automation reads must not impersonate WebView readiness or generate
        // a spectrum ACK that overwrites their own SDK response-file result.
        if (initialize_view) if (self.runtime) |runtime| self.delivery.initializeSpectrum(runtime, invocation.source.window_id);
        return result;
    }
    fn commandHandler(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *App = @ptrCast(@alignCast(context));
        var parsed = station_protocol.parseCommand(std.heap.page_allocator, invocation.request.command, invocation.request.payload) catch return station_protocol.writeAccepted(.{ .ok = false, .@"error" = .invalid_request }, output);
        defer parsed.deinit();
        const runtime = self.runtime orelse return station_protocol.writeAccepted(.{ .ok = false, .@"error" = .unsupported }, output);
        const result: station_protocol.Accepted = self.model.command(runtime.options.platform.services, parsed.command, self.now()) catch .{ .ok = false, .@"error" = .invalid_request };
        self.flush();
        return station_protocol.writeAccepted(result, output);
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
                const info = runtime.createWindow(.{ .label = "mini", .title = "SUBWAVE Mini Proof", .default_frame = native_sdk.geometry.RectF.init(80, 80, 420, 520), .min_width = 320, .min_height = 180, .source = try self.miniSource() }) catch return self.failed(output);
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
                self.delivery.initializeSpectrum(runtime, 1);
            },
        }
        return self.success(output);
    }
    fn spectrumAckHandler(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *App = @ptrCast(@alignCast(context));
        const sequence = protocol.parseSpectrumAck(invocation.request.payload) catch return invalid(output);
        const runtime = self.runtime orelse return self.failed(output);
        if (!self.delivery.acknowledge(runtime, invocation.source.window_id, self.delivery.latest_generation, sequence)) return invalid(output);
        return std.fmt.bufPrint(output, "{{\"ok\":true}}", .{});
    }
    fn diagnosticsHandler(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
        const self: *App = @ptrCast(@alignCast(context));
        if (!emptyObject(invocation.request.payload)) return invalid(output);
        const first = self.delivery.diagnostic(0);
        const second = self.delivery.diagnostic(1);
        return std.fmt.bufPrint(output, "{{\"loadCount\":{d},\"playCount\":{d},\"spectrumReceived\":{d},\"nativeSpectrumFrames\":{d},\"spectrumDelivered\":{d},\"spectrumAcked\":{d},\"maxPendingPerView\":{d},\"mainVisible\":{},\"miniVisible\":{},\"views\":[{{\"windowId\":{d},\"ready\":{},\"visible\":{},\"awaitingAck\":{},\"deliveredSequence\":{d},\"pendingSequence\":{d},\"snapshotCount\":{d},\"lastSnapshotRevision\":{d}}},{{\"windowId\":{d},\"ready\":{},\"visible\":{},\"awaitingAck\":{},\"deliveredSequence\":{d},\"pendingSequence\":{d},\"snapshotCount\":{d},\"lastSnapshotRevision\":{d}}}]}}", .{ self.model.host.audio.loads, self.model.host.audio.plays, self.delivery.sample_received, self.model.host.spectrum_sequence, self.delivery.sample_delivered, self.delivery.ack_count, self.delivery.max_pending_per_view, self.main_visible, self.mini_visible, first.window_id, first.ready, first.visible, first.awaiting_ack, first.delivered_sequence, first.pending_sequence, first.snapshot_count, first.last_snapshot_revision, second.window_id, second.ready, second.visible, second.awaiting_ack, second.delivered_sequence, second.pending_sequence, second.snapshot_count, second.last_snapshot_revision });
    }
    fn now(self: *App) u64 {
        return @intCast(@max(0, std.Io.Clock.awake.now(self.io).toMilliseconds()));
    }
    fn flush(self: *App) void {
        const runtime = self.runtime orelse return;
        const current_load = self.model.host.session.load_id;
        if (current_load != self.last_audio_load) {
            self.delivery.clearPending();
            const generation = current_load orelse self.last_audio_load orelse self.delivery.latest_generation;
            self.last_audio_load = current_load;
            self.delivery.offerSpectrum(runtime, generation, @splat(0));
        }
        if (self.last_spectrum_sequence != self.model.host.spectrum_sequence) {
            self.last_spectrum_sequence = self.model.host.spectrum_sequence;
            self.delivery.offerSpectrum(runtime, current_load orelse 0, self.model.host.spectrum);
        }
        self.pushSnapshot();
        while (self.model.nextOperation()) |operation| {
            var buffer: [512]u8 = undefined;
            const json = station_protocol.writeOperationResult(operation, &buffer) catch continue;
            for (0..2) |index| {
                const slot = self.delivery.diagnostic(index);
                if (slot.window_id != 0 and slot.ready) runtime.emitWindowEvent(slot.window_id, "subwave.player.operation", json) catch {};
            }
        }
    }
    fn pushSnapshot(self: *App) void {
        const runtime = self.runtime orelse return;
        var buffer: [station_protocol.max_snapshot_bytes]u8 = undefined;
        const snapshot = self.model.snapshot(self.now());
        const json = station_protocol.writeSnapshot(snapshot, &buffer) catch return;
        self.delivery.pushStationSnapshot(runtime, json, snapshot.revision);
    }
    fn success(self: *App, output: []u8) ![]const u8 {
        var buffer: [512]u8 = undefined;
        const snapshot = self.model.snapshot(self.now());
        const legacy = try protocol.writeSnapshot(.{ .generation = snapshot.generation, .revision = snapshot.revision, .playback = switch (snapshot.playback) {
            .stopped => .stopped,
            .loading => .loading,
            .playing => .playing,
            .paused => .paused,
            .@"error" => .@"error",
        }, .volume = @floatCast(snapshot.volume), .error_message = null }, &buffer);
        return std.fmt.bufPrint(output, "{{\"ok\":true,\"snapshot\":{s}}}", .{legacy});
    }
    fn failed(_: *App, output: []u8) ![]const u8 {
        return std.fmt.bufPrint(output, "{{\"ok\":false,\"error\":\"failed\"}}", .{});
    }
    fn miniSource(self: *App) !native_sdk.WebViewSource {
        if (self.env_map.get("NATIVE_SDK_FRONTEND_URL")) |url| {
            const joined = try std.fmt.bufPrint(&self.mini_source_store, "{s}{s}foundation=1&view=mini", .{ url, if (std.mem.indexOfScalar(u8, url, '?') == null) "?" else "&" });
            return native_sdk.WebViewSource.url(joined);
        }
        // A plain zero:// URL does not install an asset root for a newly
        // created WebView. Keep this an asset source so the second window
        // owns its resolver; Linux preserves the query on the entry URL
        // while resolving the file path without it.
        return self.frontendSource("index.html?foundation=1&view=mini");
    }

    fn frontendSource(self: *App, entry: []const u8) !native_sdk.WebViewSource {
        if (self.env_map.get("NATIVE_SDK_FRONTEND_URL")) |url| {
            if (url.len > 0) {
                const target = try std.fmt.bufPrint(&self.mini_source_store, "{s}{s}foundation=1", .{ url, if (std.mem.indexOfScalar(u8, url, '?') == null) "?" else "&" });
                return native_sdk.WebViewSource.url(target);
            }
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
    defer {
        state.model.deinit();
        std.heap.page_allocator.destroy(state.model);
    }
    try runner.runWithOptions(state.app(), .{ .app_name = "SUBWAVE Player Preview", .window_title = "SUBWAVE Player Preview", .bundle_id = "dev.subwave.player.webviewproof", .icon_path = "assets/icon.png", .bridge = state.bridge(), .credentials_enabled = true, .security = .{ .permissions = &.{native_sdk.security.permission_credentials}, .navigation = .{ .allowed_origins = allowedOrigins() } }, .js_window_api = true }, init_value);
}

test "foundation privileges separate production development and automation origins" {
    try std.testing.expectEqual(@as(usize, 1), originsFor(false, false).len);
    try std.testing.expectEqualStrings("zero://app", originsFor(false, false)[0]);
    try std.testing.expectEqualStrings("zero://inline", originsFor(true, false)[1]);
    try std.testing.expectEqualStrings("http://127.0.0.1:5173", originsFor(false, true)[1]);
}

test {
    _ = model_mod;
    _ = view_delivery;
    _ = automation_vault;
}
