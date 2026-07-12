//! Phase 0 audio spike: prove the effects channel end-to-end against the live
//! SUB/WAVE station — stream `/stream.mp3` via fx.playAudio and poll
//! `/api/now-playing` on a 5s timer via fx.fetch, rendering every observed
//! event so `native automate snapshot` can read it. On Linux we expect the
//! audio event to be `.failed` (GTK has no audio backend yet — macOS only);
//! the HTTP/feed half should work everywhere.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
const window_width: f32 = 560;
const window_height: f32 = 320;

const station = "https://www.getsubwave.com";
const stream_url = station ++ "/stream.mp3";
const np_url = station ++ "/api/now-playing";

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Probe canvas", .accessibility_label = "Probe", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    // NOTE: a "/" here crashes GTK at app_start on Linux (the scene/shell title
    // is used in a GAction/GMenu path context). Keep the branded "SUB/WAVE"
    // slash out of the *scene* title; runWithOptions.window_title tolerates it.
    .title = "SUBWAVE Probe",
    .width = window_width,
    .height = window_height,
    .restore_state = false,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ---------------------------------------------------------------- effect keys

const keys = struct {
    const audio: u64 = 10;
    const feed_timer: u64 = 1;
    const fetch_np: u64 = 20;
};

// ------------------------------------------------------------------ model

pub const Msg = union(enum) {
    tick_feed: native_sdk.EffectTimer,
    got_np: native_sdk.EffectResponse,
    audio_event: native_sdk.EffectAudio,
};

pub const Model = struct {
    title_buf: [256]u8 = undefined,
    artist_buf: [256]u8 = undefined,
    title: []const u8 = "(waiting)",
    artist: []const u8 = "",
    audio_state: []const u8 = "idle",
    last_outcome: []const u8 = "-",
    elapsed_ms: i64 = 0,
    http_status: i64 = 0,
    feed_count: i64 = 0,
    pos_count: i64 = 0,
    buffering: bool = false,
};

const App = native_sdk.UiApp(Model, Msg);
const Effects = App.Effects;

fn startStream(model: *Model, fx: *Effects) void {
    fx.playAudio(.{
        .key = keys.audio,
        .path = "",
        .url = stream_url,
        .cache_path = "", // stream-only, no disk cache — the endless-stream case
        .expected_bytes = 0,
        .on_event = Effects.audioMsg(.audio_event),
    });
    fx.setAudioVolume(0.0); // muted during the spike soak — decode/position/spectrum still report
    model.audio_state = "starting";
}

fn fetchNp(fx: *Effects) void {
    fx.fetch(.{
        .key = keys.fetch_np,
        .url = np_url,
        .on_response = Effects.responseMsg(.got_np),
    });
}

// Crude JSON field lift for the spike — find `"<name>":"` and copy until the
// next quote. Good enough to prove real data reaches the model (the real app
// uses std.json). Titles here carry no embedded quotes.
fn extractField(body: []const u8, needle: []const u8, buf: []u8, out: *[]const u8) void {
    const i = std.mem.indexOf(u8, body, needle) orelse return;
    const start = i + needle.len;
    var j = start;
    while (j < body.len and body[j] != '"') : (j += 1) {}
    const val = body[start..j];
    const n = @min(val.len, buf.len);
    @memcpy(buf[0..n], val[0..n]);
    out.* = buf[0..n];
}

fn boot(model: *Model, fx: *Effects) void {
    startStream(model, fx);
    fetchNp(fx);
    fx.startTimer(.{
        .key = keys.feed_timer,
        .interval_ms = 5000,
        .mode = .repeating,
        .on_fire = Effects.timerMsg(.tick_feed),
    });
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .tick_feed => |t| {
            if (t.outcome == .fired) fetchNp(fx);
        },
        .got_np => |r| {
            model.feed_count += 1;
            model.last_outcome = @tagName(r.outcome);
            if (r.outcome == .ok) {
                model.http_status = @intCast(r.status);
                extractField(r.body, "\"title\":\"", &model.title_buf, &model.title);
                extractField(r.body, "\"artist\":\"", &model.artist_buf, &model.artist);
            }
        },
        .audio_event => |e| {
            model.audio_state = @tagName(e.kind);
            if (e.kind == .position) {
                model.pos_count += 1;
                model.elapsed_ms = @intCast(e.position_ms);
                model.buffering = e.buffering;
            }
        },
    }
}

// ------------------------------------------------------------------- view

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

// -------------------------------------------------------------------- app

pub fn initialModel() Model {
    return .{};
}

pub fn main(init: std.process.Init) !void {
    const app_state = try App.create(std.heap.page_allocator, .{
        .name = "subwave-desktop",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .init_fx = boot,
        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io },
    });
    defer app_state.destroy();
    app_state.model = initialModel();

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "subwave-desktop",
        .window_title = "SUB/WAVE Probe",
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
