//! Thin entry point: shell/window config + App wiring. State lives in
//! model.zig; the view is app.native.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const model = @import("model.zig");
const theme = @import("theme.zig");
const skins = @import("skins.zig");
const settings = @import("settings.zig");
const api = @import("api.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
const window_width: f32 = 620;
const window_height: f32 = 460;

// Re-exports for tests.zig.
pub const Model = model.Model;
pub const Msg = model.Msg;
pub const AppUi = canvas.Ui(Msg);

// ------------------------------------------------------- OS integration seams
// App-level key fallback — consulted only for keys no focused widget consumed
// (typing in the request/station fields is never stolen): the bare-space
// play/pause convention plus arrow-key volume.
fn onKey(keyboard: canvas.WidgetKeyboardEvent) ?Msg {
    if (keyboard.phase != .key_down) return null;
    const mods = keyboard.modifiers;
    if (mods.control or mods.alt or mods.super) return null;
    const key = keyboard.key;
    if (std.ascii.eqlIgnoreCase(key, "space")) return .toggle_play;
    if (std.ascii.eqlIgnoreCase(key, "arrowup") or std.ascii.eqlIgnoreCase(key, "up")) return .vol_up;
    if (std.ascii.eqlIgnoreCase(key, "arrowdown") or std.ascii.eqlIgnoreCase(key, "down")) return .vol_down;
    return null;
}

// Status-item menu selections arrive as named commands (source .tray).
fn onCommand(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, "toggle-play")) return .toggle_play;
    if (std.mem.eql(u8, name, "tune-out")) return .tune_out;
    return null;
}

// Menu-bar extra (macOS NSStatusItem; platforms without a tray log once and
// continue): live now-playing readout + transport, so the player stays
// controllable while the window is buried.
fn statusItem(m: *const Model, scratch: *model.App.StatusItemScratch) model.App.StatusItemState {
    var n: usize = 0;
    scratch.items[n] = .{ .id = 1, .label = m.title, .enabled = false };
    n += 1;
    if (m.artist.len > 0) {
        scratch.items[n] = .{ .id = 2, .label = m.artist, .enabled = false };
        n += 1;
    }
    scratch.items[n] = .{ .id = 3, .separator = true };
    n += 1;
    scratch.items[n] = .{ .id = 4, .label = m.play_label(), .command = "toggle-play" };
    n += 1;
    scratch.items[n] = .{ .id = 5, .label = "Tune out", .command = "tune-out" };
    n += 1;
    const title: []const u8 = if (m.transport == .playing) "S/W ♪" else "S/W";
    return .{ .title = title, .items = scratch.items[0..n] };
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
    .restore_state = false,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

pub fn main(init: std.process.Init) !void {
    const app_state = try model.App.create(std.heap.page_allocator, .{
        .name = "subwave",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = model.update,
        .init_fx = model.boot,
        .tokens_fn = theme.tokensFn,
        .view = skins.rootView,
        .on_key = onKey,
        .on_command = onCommand,
        .status_item = .{ .tooltip = "SUB/WAVE Player" },
        .status_item_fn = statusItem,
    });
    defer app_state.destroy();
    app_state.model = model.initialModel();

    // Load persisted settings (volume/skin/theme/station) BEFORE the window
    // opens, so the startup window size can follow the saved skin. Also honor a
    // SUBWAVE_STATION_URL env override (wins over the persisted station).
    settings.resolvePath(&app_state.model, init.environ_map);
    settings.loadFromDisk(&app_state.model, init.io);
    if (init.environ_map.get("SUBWAVE_STATION_URL")) |env_station| {
        if (env_station.len > 0) {
            if (api.normalizeBase(&app_state.model.base_buf, env_station)) |b| app_state.model.base = b else |_| {}
        }
    }

    // The SDK can't resize a live window, so the window SHAPE follows the saved
    // skin at startup: Deck opens compact, Card roomy. (Live skin switch changes
    // the layout in place; the shape applies on next launch.)
    const frame = if (app_state.model.skin == .deck)
        geometry.RectF.init(0, 0, 540, 300)
    else
        geometry.RectF.init(0, 0, window_width, window_height);

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "subwave",
        .window_title = "SUB/WAVE",
        .bundle_id = "dev.subwave.player",
        .icon_path = "assets/icon.png",
        .default_frame = frame,
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

test "key fallback maps space/arrows to transport msgs, modifiers excluded" {
    try testing.expect(onKey(.{ .phase = .key_down, .key = "space" }).? == .toggle_play);
    try testing.expect(onKey(.{ .phase = .key_down, .key = "ArrowUp" }).? == .vol_up);
    try testing.expect(onKey(.{ .phase = .key_down, .key = "arrowdown" }).? == .vol_down);
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
    try testing.expectEqual(@as(usize, 5), state.items.len);
    try testing.expectEqualStrings("Night Drive", state.items[0].label);
    try testing.expect(!state.items[0].enabled);
    try testing.expectEqualStrings("Pause", state.items[3].label);
    try testing.expect(onCommand(state.items[3].command).? == .toggle_play);
    try testing.expect(onCommand(state.items[4].command).? == .tune_out);
    try testing.expect(onCommand("unknown") == null);
}
