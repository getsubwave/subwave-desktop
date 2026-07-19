//! Thin entry point: shell/window config + App wiring. State lives in
//! model.zig; the views are views/*.native (see views.zig).

const std = @import("std");
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

// Status-item menu selections arrive as named commands (source .tray).
// "open-player" and "quit" are handled host-side (reserved tray ids 100/101
// in the local SDK patch — unhide / terminate are outside the model's reach),
// so they map to no Msg here.
fn onCommand(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, "tune-toggle")) return .tune_toggle;
    if (std.mem.eql(u8, name, "toggle-mute")) return .toggle_mute;
    if (std.mem.eql(u8, name, "sleep-cycle")) return .sleep_cycle;
    if (std.mem.eql(u8, name, "toggle-mini")) return .toggle_mini;
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
    // Reserved ids (local SDK patch): 100 unhides + activates the app,
    // 101 terminates — both before the command callback dispatches.
    scratch.items[n] = .{ .id = 100, .label = "Open player", .command = "open-player" };
    n += 1;
    scratch.items[n] = .{ .id = 9, .label = if (m.mini_open) "Close mini player" else "Mini player", .command = "toggle-mini" };
    n += 1;
    scratch.items[n] = .{ .id = 10, .separator = true };
    n += 1;
    scratch.items[n] = .{ .id = 101, .label = "Quit SUB/WAVE", .command = "quit" };
    n += 1;
    const title: []const u8 = if (m.transport == .playing) "S/W ♪" else "S/W";
    return .{ .title = title, .items = scratch.items[0..n] };
}

// Hidden-titlebar chrome geometry → model (masthead pads around the traffic
// lights). All-zero on standard chrome / fullscreen / non-macOS.
fn onChrome(chrome: native_sdk.platform.WindowChrome) ?Msg {
    return Msg{ .chrome_changed = .{
        .top = chrome.insets.top,
        .leading = chrome.insets.left,
    } };
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
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

pub fn main(init: std.process.Init) !void {
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
    try testing.expectEqual(@as(u32, 100), @as(u32, @intCast(state.items[7].id)));
    try testing.expect(onCommand(state.items[7].command) == null); // host-side action
    try testing.expectEqualStrings("Quit SUB/WAVE", state.items[10].label);
    try testing.expect(onCommand("toggle-mini").? == .toggle_mini);
    try testing.expect(onCommand("unknown") == null);
}
