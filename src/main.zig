//! Thin entry point: shell/window config + App wiring. State lives in
//! model.zig; the view is app.native.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const model = @import("model.zig");
const theme = @import("theme.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
const window_width: f32 = 620;
const window_height: f32 = 400;

// Re-exports for tests.zig.
pub const Model = model.Model;
pub const Msg = model.Msg;
pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

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
        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io },
    });
    defer app_state.destroy();
    app_state.model = model.initialModel();

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
