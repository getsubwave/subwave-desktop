//! Thin entry point: shell/window config + App wiring. State lives in
//! model.zig; the views are views/*.native (see views.zig).

const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const model = @import("model.zig");
const theme = @import("theme.zig");
const views = @import("views.zig");
const settings = @import("settings.zig");
const api = @import("api.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
const window_width: f32 = 980;
const window_height: f32 = 660;

// Re-exports for tests.zig.
pub const Model = model.Model;
pub const Msg = model.Msg;
pub const AppUi = canvas.Ui(Msg);

// ------------------------------------------------------------- app icons
// Registered at boot; markup reaches them as icon="app:disc" / "app:power".
// `pub const app_icons` is the model-contract mirror `native check` verifies
// markup names against.
const disc_icon = canvas.svg_icon.parseComptime(@embedFile("icons/disc.svg"));
const heart_icon = canvas.svg_icon.parseComptime(@embedFile("icons/heart.svg"));
const heart_fill_icon = canvas.svg_icon.parseComptime(@embedFile("icons/heart-fill.svg"));
const logo_icon = canvas.svg_icon.parseComptime(@embedFile("icons/logo.svg"));
const power_icon = canvas.svg_icon.parseComptime(@embedFile("icons/power.svg"));
const radio_icon = canvas.svg_icon.parseComptime(@embedFile("icons/radio.svg"));
const spark_icon = canvas.svg_icon.parseComptime(@embedFile("icons/spark.svg"));
pub const app_icons = [_]canvas.icons.Entry{
    .{ .name = "disc", .icon = &disc_icon },
    .{ .name = "heart", .icon = &heart_icon },
    .{ .name = "heart-fill", .icon = &heart_fill_icon },
    .{ .name = "logo", .icon = &logo_icon },
    .{ .name = "power", .icon = &power_icon },
    .{ .name = "radio", .icon = &radio_icon },
    .{ .name = "spark", .icon = &spark_icon },
};

// ------------------------------------------------------- OS integration seams
// App-level key fallback — consulted only for keys no focused widget consumed
// (typing in the request/station fields is never stolen). Space = tune toggle,
// arrows = volume, M = mute, cmd/ctrl+K = stations, Esc = back to LIVE,
// 1–5 = dial stops.
fn onKey(keyboard: canvas.WidgetKeyboardEvent) ?Msg {
    if (keyboard.phase != .key_down) return null;
    const mods = keyboard.modifiers;
    const key = keyboard.key;
    if (mods.super or mods.control) {
        if (!mods.alt and std.ascii.eqlIgnoreCase(key, "k")) return .toggle_sidebar;
        return null;
    }
    if (mods.alt) return null;
    if (std.ascii.eqlIgnoreCase(key, "space")) return .toggle_play;
    if (std.ascii.eqlIgnoreCase(key, "arrowup") or std.ascii.eqlIgnoreCase(key, "up")) return .vol_up;
    if (std.ascii.eqlIgnoreCase(key, "arrowdown") or std.ascii.eqlIgnoreCase(key, "down")) return .vol_down;
    if (std.ascii.eqlIgnoreCase(key, "m")) return .toggle_mute;
    if (std.ascii.eqlIgnoreCase(key, "l")) return .press_like;
    if (std.ascii.eqlIgnoreCase(key, "escape")) return .escape;
    if (key.len == 1) {
        switch (key[0]) {
            '1' => return .{ .pick_tab = .schedule },
            '2' => return .{ .pick_tab = .timeline },
            '3' => return .{ .pick_tab = .live },
            '4' => return .{ .pick_tab = .booth },
            '5' => return .{ .pick_tab = .request },
            else => {},
        }
    }
    return null;
}

// Status-item menu selections arrive as named commands (source .tray). Every
// row is a real Msg now: SDK 0.6.0 gave the model `fx.showWindow` / `fx.quitApp`,
// so "Open player" and "Quit" no longer need the reserved host-side tray ids
// the old local patch carved out (and they work on every platform's tray, not
// just the patched macOS one).
fn onCommand(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, "tune-toggle")) return .tune_toggle;
    if (std.mem.eql(u8, name, "toggle-mute")) return .toggle_mute;
    if (std.mem.eql(u8, name, "sleep-cycle")) return .sleep_cycle;
    if (std.mem.eql(u8, name, "toggle-mini")) return .toggle_mini;
    if (std.mem.eql(u8, name, "open-player")) return .show_player;
    if (std.mem.eql(u8, name, "quit")) return .quit_app;
    return null;
}

// Menu-bar extra (macOS NSStatusItem; platforms without a tray log once and
// continue): live now-playing readout + transport, so the player stays
// controllable while the window is buried. The design's tray popover is a
// custom surface the SDK's status item can't draw — this is the honest
// native-menu projection of the same content.
fn statusItem(m: *const Model, scratch: *model.App.StatusItemScratch) model.App.StatusItemState {
    var n: usize = 0;
    scratch.items[n] = .{ .id = 1, .label = if (m.tray_track.len > 0) m.tray_track else m.title, .enabled = false };
    n += 1;
    if (m.tray_status.len > 0) {
        scratch.items[n] = .{ .id = 2, .label = m.tray_status, .enabled = false };
        n += 1;
    }
    scratch.items[n] = .{ .id = 3, .separator = true };
    n += 1;
    scratch.items[n] = .{ .id = 4, .label = if (m.transport == .stopped) "Tune in" else "Tune out", .command = "tune-toggle" };
    n += 1;
    scratch.items[n] = .{ .id = 5, .label = m.mute_label(), .command = "toggle-mute" };
    n += 1;
    scratch.items[n] = .{ .id = 6, .separator = true };
    n += 1;
    // Cycles off -> 15 -> 30 -> 45 -> 60 -> 90 -> off (flat menu: the SDK
    // tray has no submenus; labels are static per armed value).
    const sleep_label: []const u8 = switch (m.sleep_minutes) {
        15 => "Sleep timer: 15 min",
        30 => "Sleep timer: 30 min",
        45 => "Sleep timer: 45 min",
        60 => "Sleep timer: 60 min",
        90 => "Sleep timer: 90 min",
        else => "Sleep timer: off",
    };
    scratch.items[n] = .{ .id = 7, .label = sleep_label, .command = "sleep-cycle" };
    n += 1;
    scratch.items[n] = .{ .id = 8, .separator = true };
    n += 1;
    scratch.items[n] = .{ .id = 9, .label = "Open player", .command = "open-player" };
    n += 1;
    scratch.items[n] = .{ .id = 10, .label = if (m.mini_open) "Close mini player" else "Mini player", .command = "toggle-mini" };
    n += 1;
    scratch.items[n] = .{ .id = 11, .separator = true };
    n += 1;
    scratch.items[n] = .{ .id = 12, .label = "Quit SUB/WAVE", .command = "quit" };
    n += 1;
    const title: []const u8 = if (m.transport == .playing) "S/W ♪" else "S/W";
    return .{ .title = title, .items = scratch.items[0..n] };
}

// App-level lifecycle → model. Only the activate/deactivate edges are of
// interest: `.frame` fires every frame and `.start`/`.stop` are already covered
// by boot and teardown, so mapping them would be per-frame dispatch for nothing.
fn onLifecycle(event: native_sdk.LifecycleEvent) ?Msg {
    return switch (event) {
        .activate => .app_activated,
        .deactivate => .app_deactivated,
        else => null,
    };
}

// Hidden-titlebar chrome geometry → model (masthead pads around the traffic
// lights). All-zero on standard chrome / fullscreen / non-macOS.
fn onChrome(chrome: native_sdk.platform.WindowChrome) ?Msg {
    return Msg{ .chrome_changed = .{
        .top = chrome.insets.top,
        .leading = chrome.insets.left,
    } };
}

// --------------------------------------------------- Discord RPC helper mode
// The app re-invokes its own binary with argv[1] == "--discord-rpc-helper"
// (see model.zig's respawnDiscordHelper) as a short-lived child process that
// owns the raw Discord IPC socket I/O. Kept out of the main event loop
// because this is a genuinely separate process, not an SDK effect.
fn isDiscordHelperMode(init: std.process.Init) bool {
    const argv = init.minimal.args.toSlice(init.arena.allocator()) catch return false;
    return argv.len > 1 and std.mem.eql(u8, argv[1], "--discord-rpc-helper");
}

// Reads one activity JSON payload from stdin, connects to Discord's local
// IPC endpoint, completes the handshake, sends SET_ACTIVITY, prints one
// status line, then blocks (reading from the connection) until fx.cancel
// SIGKILLs this process — that's what keeps the presence visible, since
// Discord clears it the instant the connection closes.
//
// Transport differs by platform (Discord's choice, not ours): macOS/Linux
// expose the IPC endpoint as a Unix domain socket file under
// $TMPDIR/$XDG_RUNTIME_DIR (discord_rpc.resolveSocketPath), but Windows has
// no AF_UNIX equivalent for this — Discord instead listens on a named pipe
// at \\.\pipe\discord-ipc-N, the same convention every third-party Discord
// RPC client on Windows relies on. Once open, a named pipe HANDLE behaves
// like an ordinary file handle for read/write purposes, and
// std.Io.Dir.openFileAbsolute already lowers an absolute `\\.\pipe\...`
// path to the right NtCreateFile call on Windows — so the Windows branch
// only has to pick the transport; the handshake/SET_ACTIVITY/blocking-read
// protocol logic below (runDiscordSession) is written once and shared
// across both platforms via a std.Io.net.Stream on macOS/Linux or a
// std.Io.File on Windows, since both expose the same reader()/writer()/
// close() shape.
fn runDiscordHelper(init: std.process.Init) void {
    const io = init.io;
    const alloc = init.arena.allocator();
    const stdout = std.Io.File.stdout();

    var stdin_buf: [64]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
    const request_json = stdin_reader.interface.allocRemaining(alloc, .limited(2048)) catch {
        stdout.writeStreamingAll(io, "ERROR: bad payload\n") catch {};
        return;
    };

    if (builtin.os.tag == .windows) {
        const pipe = connectDiscordPipe(io) orelse {
            stdout.writeStreamingAll(io, "ERROR: Discord not running\n") catch {};
            return;
        };
        defer pipe.close(io);
        runDiscordSession(io, alloc, stdout, request_json, pipe);
        return;
    }

    // Scan subdir x index the same way the Windows branch scans pipe
    // indices: a plain install parks the socket at <base>/discord-ipc-N,
    // Flatpak/Snap installs remap it into an app subdirectory, and N can be
    // above 0 when another RPC client already holds the low slots.
    const discord_rpc = @import("discord_rpc.zig");
    var path_buf: [256]u8 = undefined;
    const stream = blk: {
        for (discord_rpc.socket_subdirs) |subdir| {
            var n: u8 = 0;
            while (n < 10) : (n += 1) {
                const socket_path = discord_rpc.resolveSocketPath(
                    &path_buf,
                    init.environ_map.get("XDG_RUNTIME_DIR"),
                    init.environ_map.get("TMPDIR"),
                    init.environ_map.get("TMP"),
                    subdir,
                    n,
                ) catch continue;
                const address = std.Io.net.UnixAddress.init(socket_path) catch continue;
                break :blk address.connect(io) catch continue;
            }
        }
        stdout.writeStreamingAll(io, "ERROR: Discord not running\n") catch {};
        return;
    };
    defer stream.close(io);
    runDiscordSession(io, alloc, stdout, request_json, stream);
}

// Windows-only: Discord's RPC server listens on \\.\pipe\discord-ipc-N,
// trying N in sequence (0, 1, 2, ...) until one is live — the same
// discovery convention every other Discord RPC client uses on Windows,
// since there's no env-var-based lookup the way there is for the
// macOS/Linux socket path. Returns the first pipe that opens; null if none
// of the first 10 do (Discord not running, or not accepting RPC clients).
fn connectDiscordPipe(io: std.Io) ?std.Io.File {
    var name_buf: [32]u8 = undefined;
    var n: u8 = 0;
    while (n < 10) : (n += 1) {
        const path = std.fmt.bufPrint(&name_buf, "\\\\.\\pipe\\discord-ipc-{d}", .{n}) catch unreachable;
        const pipe = std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write }) catch continue;
        return pipe;
    }
    return null;
}

// The actual Discord IPC protocol sequence, identical on every platform:
// parse the raw request from stdin, write the opcode-0 handshake, wait for
// the opcode-1 READY dispatch (read + discard by header length), build the
// real activity JSON (converting elapsed_ms to absolute timestamps using
// this process's real clock) and write it as the opcode-1 SET_ACTIVITY
// frame, announce readiness on stdout, then block reading until the
// connection closes or errors. `conn` is a std.Io.net.Stream (macOS/Linux)
// or a std.Io.File (Windows) — both expose reader()/writer()/close() with
// the same shape, so this is written once and shared rather than
// duplicated per platform.
fn runDiscordSession(io: std.Io, alloc: std.mem.Allocator, stdout: std.Io.File, request_json: []const u8, conn: anytype) void {
    const discord_rpc = @import("discord_rpc.zig");
    const json = @import("json.zig");
    // Linux takes the raw-syscall getpid: `native test`'s analysis object
    // compiles this module without libc, so std.c.getpid (an extern "c"
    // symbol) is a compile error there. macOS always links libc.
    const pid: i32 = switch (builtin.os.tag) {
        .windows => @bitCast(std.os.windows.GetCurrentProcessId()),
        .linux => @intCast(std.os.linux.getpid()),
        else => std.c.getpid(),
    };

    // model.zig's update() is a pure reducer with no wall clock, so it
    // sends the raw display fields + elapsed_ms/duration_s (see
    // discord_rpc.ActivityRequest) instead of a ready-made activity object.
    const parsed = json.parse(discord_rpc.ActivityRequest, alloc, request_json) catch {
        stdout.writeStreamingAll(io, "ERROR: bad payload\n") catch {};
        return;
    };
    const req = parsed.value;

    var frame_buf: [2560]u8 = undefined;
    const handshake = discord_rpc.encodeHandshakeFrame(&frame_buf, discord_rpc.client_id) catch {
        stdout.writeStreamingAll(io, "ERROR: handshake encode failed\n") catch {};
        return;
    };
    var write_buf: [512]u8 = undefined;
    var writer = conn.writer(io, &write_buf);
    writer.interface.writeAll(handshake) catch {
        stdout.writeStreamingAll(io, "ERROR: handshake write failed\n") catch {};
        return;
    };
    writer.interface.flush() catch {};

    // The READY dispatch (opcode 1, a JSON event) — read and discard the
    // header + body; a successful read this far means Discord accepted
    // the handshake.
    var read_buf: [4096]u8 = undefined;
    var reader = conn.reader(io, &read_buf);
    var header: [8]u8 = undefined;
    reader.interface.readSliceAll(&header) catch {
        stdout.writeStreamingAll(io, "ERROR: no handshake response\n") catch {};
        return;
    };
    const ready_len = std.mem.readInt(u32, header[4..8], .little);
    reader.interface.discardAll(ready_len) catch {};

    // Convert elapsed_ms to an absolute epoch-ms start (and end, if
    // duration is known) using this process's real clock, right before
    // sending — the anchor is only ever computed at the moment we're
    // actually about to tell Discord "this is playing now", not on every
    // now-playing poll (see buildActivityRequestJson's doc comment for why
    // that matters).
    const now_ms = std.Io.Clock.real.now(io).toMilliseconds();
    const start_ms = now_ms - req.elapsed_ms;
    const timestamps: discord_rpc.Timestamps = .{
        .start_ms = start_ms,
        .end_ms = if (req.duration_s > 0) start_ms + req.duration_s * 1000 else null,
    };
    var activity_body_buf: [2048]u8 = undefined;
    const activity_json = discord_rpc.buildActivityJson(&activity_body_buf, req.details, req.state, req.url, req.cover_url, now_ms, timestamps) catch {
        stdout.writeStreamingAll(io, "ERROR: activity build failed\n") catch {};
        return;
    };

    // pid must be a real, currently-running process id — Discord clients
    // silently drop SET_ACTIVITY when it doesn't correspond to one (an
    // anti-spoofing check so a stale/ghost activity can't outlive the
    // process that set it). Use this helper's own pid, not the parent
    // app's: this process is the one holding the IPC connection open.
    const activity_frame = discord_rpc.encodeActivityFrame(&frame_buf, pid, activity_json) catch {
        stdout.writeStreamingAll(io, "ERROR: activity encode failed\n") catch {};
        return;
    };
    writer.interface.writeAll(activity_frame) catch {
        stdout.writeStreamingAll(io, "ERROR: activity write failed\n") catch {};
        return;
    };
    writer.interface.flush() catch {};

    stdout.writeStreamingAll(io, "READY\n") catch {};

    // Block until killed (fx.cancel SIGKILLs this process) — closing the
    // connection ourselves would clear the presence early. Uses
    // readSliceAll (not readSliceShort): a graceful peer close (e.g. the
    // user quits Discord) is a 0-byte OS read, which the reader's readVec
    // turns into error.EndOfStream — readSliceAll re-raises that (its
    // ShortError includes EndOfStream) so `catch break` actually fires and
    // this function returns, letting the spawn's on_exit reach model.zig.
    // readSliceShort's ShortError deliberately excludes EndOfStream (short
    // reads aren't meant to error), so it would instead return an Ok(0)
    // forever and spin this loop tight without ever returning.
    while (true) {
        var discard: [256]u8 = undefined;
        reader.interface.readSliceAll(&discard) catch break;
    }
}

// Mirror runtime-owned widget values into the model before update/rebuild:
// the transport deck's volume slider is the one continuous control.
fn syncModel(m: *Model, layout: canvas.WidgetLayoutTree) void {
    for (layout.nodes) |node| {
        if (node.widget.kind != .slider) continue;
        if (std.mem.eql(u8, node.widget.semantics.label, "Volume")) {
            m.volume = std.math.clamp(node.widget.value, 0.0, 1.0);
        }
    }
}

// Model-declared secondary windows: the mini player.
fn windowsFn(m: *const Model, scratch: *model.App.WindowsScratch) []const model.App.WindowDescriptor {
    var count: usize = 0;
    if (m.mini_open) {
        scratch.windows[count] = .{
            .label = "mini",
            .canvas_label = "mini-canvas",
            .title = "SUB/WAVE Mini",
            .width = 420,
            .height = 168,
            .resizable = false,
            .titlebar = .hidden_inset,
            .on_close = .mini_closed,
        };
        count += 1;
    }
    return scratch.windows[0..count];
}

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Player canvas", .accessibility_label = "Player", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
// NOTE: no "/" in the scene title — a slash here crashes GTK at app_start on
// Linux (Phase 0 finding). The branded slash rides runWithOptions.window_title.
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "SUBWAVE",
    .width = window_width,
    .height = window_height,
    .min_width = 880,
    .min_height = 560,
    .restore_state = false,
    .titlebar = .hidden_inset_tall,
    // NOTE: close_policy is NOT set here. Close handling is host window state
    // fixed at create time, so the STARTUP window takes it from app.zon (the
    // host creates the window before this scene loads); declaring it here would
    // read as authoritative and never apply. See app.zon / docs/sdk-notes.md.
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

pub fn main(init: std.process.Init) !void {
    if (isDiscordHelperMode(init)) return runDiscordHelper(init);
    canvas.icons.registerAppIcons(&app_icons);

    const app_state = try model.App.create(std.heap.page_allocator, .{
        .name = "subwave",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = model.update,
        .init_fx = model.boot,
        .tokens_fn = theme.tokensFn,
        .view = views.rootView,
        .windows_fn = windowsFn,
        .window_view = views.windowView,
        .on_key = onKey,
        .on_command = onCommand,
        .on_lifecycle = onLifecycle,
        .on_chrome = onChrome,
        .sync = syncModel,
        .status_item = .{ .tooltip = "SUB/WAVE Player" },
        .status_item_fn = statusItem,
    });
    defer app_state.destroy();
    app_state.model = model.initialModel();

    // Load persisted settings (volume/theme/station/recents) BEFORE the window
    // opens — a saved station skips onboarding. Also honor a
    // SUBWAVE_STATION_URL env override (wins over the persisted station).
    settings.resolvePath(&app_state.model, init.environ_map);
    settings.loadFromDisk(&app_state.model, init.io);
    const exe_len = std.process.executablePath(init.io, &app_state.model.self_exe_path_buf) catch 0;
    app_state.model.self_exe_path = app_state.model.self_exe_path_buf[0..exe_len];
    if (init.environ_map.get("SUBWAVE_STATION_URL")) |env_station| {
        if (env_station.len > 0) {
            if (api.normalizeBase(&app_state.model.base_buf, env_station)) |b| {
                app_state.model.base = b;
                app_state.model.phase = .player;
            } else |_| {}
        }
    }

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "subwave",
        .window_title = "SUB/WAVE",
        .bundle_id = "dev.subwave.player",
        .icon_path = "assets/icon.png",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}

const testing = std.testing;

test "key fallback maps transport, navigation, and dial keys" {
    try testing.expect(onKey(.{ .phase = .key_down, .key = "space" }).? == .toggle_play);
    try testing.expect(onKey(.{ .phase = .key_down, .key = "ArrowUp" }).? == .vol_up);
    try testing.expect(onKey(.{ .phase = .key_down, .key = "arrowdown" }).? == .vol_down);
    try testing.expect(onKey(.{ .phase = .key_down, .key = "M" }).? == .toggle_mute);
    try testing.expect(onKey(.{ .phase = .key_down, .key = "L" }).? == .press_like);
    try testing.expect(onKey(.{ .phase = .key_down, .key = "Escape" }).? == .escape);
    try testing.expect(onKey(.{ .phase = .key_down, .key = "k", .modifiers = .{ .super = true } }).? == .toggle_sidebar);
    try testing.expectEqual(Msg{ .pick_tab = .booth }, onKey(.{ .phase = .key_down, .key = "4" }).?);
    try testing.expect(onKey(.{ .phase = .key_up, .key = "space" }) == null);
    try testing.expect(onKey(.{ .phase = .key_down, .key = "space", .modifiers = .{ .super = true } }) == null);
    try testing.expect(onKey(.{ .phase = .key_down, .key = "a" }) == null);
}

test "lifecycle maps only the activate/deactivate edges" {
    try testing.expect(onLifecycle(.activate).? == .app_activated);
    try testing.expect(onLifecycle(.deactivate).? == .app_deactivated);
    // .frame arrives every frame — mapping it would dispatch a Msg per frame.
    try testing.expect(onLifecycle(.frame) == null);
    try testing.expect(onLifecycle(.start) == null);
    try testing.expect(onLifecycle(.stop) == null);
}

test "status-item menu derives from the model and maps commands back" {
    var m: Model = .{};
    m.title = "Night Drive";
    m.artist = "The Midnight";
    var scratch: model.App.StatusItemScratch = .{};
    const state = statusItem(&m, &scratch);
    try testing.expectEqualStrings("S/W ♪", state.title); // default transport = playing
    try testing.expectEqualStrings("Night Drive", state.items[0].label); // tray_track empty -> title
    try testing.expect(!state.items[0].enabled);
    try testing.expectEqualStrings("Tune out", state.items[2].label);
    try testing.expect(onCommand(state.items[2].command).? == .tune_toggle);
    try testing.expectEqualStrings("Sleep timer: off", state.items[5].label);
    try testing.expect(onCommand(state.items[5].command).? == .sleep_cycle);
    try testing.expectEqualStrings("Open player", state.items[7].label);
    try testing.expect(onCommand(state.items[7].command).? == .show_player);
    try testing.expectEqualStrings("Quit SUB/WAVE", state.items[10].label);
    try testing.expect(onCommand(state.items[10].command).? == .quit_app);
    try testing.expect(onCommand("toggle-mini").? == .toggle_mini);
    try testing.expect(onCommand("unknown") == null);
}
