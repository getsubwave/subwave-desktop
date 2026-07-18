//! Station theme → Native SDK DesignTokens. Maps the 7 resolved station colors
//! onto the DesignTokens color slots and derives the live token set the runtime
//! re-reads every rebuild (so a /api/themes change reskins without a restart).

const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const color = @import("color.zig");
const model_mod = @import("model.zig");

// The 7 station tokens projected onto DesignTokens color slots. Only color
// slots are written — the app's own material (controls, radius, typography)
// survives, which is what lets one theme repaint every surface.
pub fn stationOverrides(sc: color.StationColors) canvas.DesignTokenOverrides {
    return .{ .colors = .{
        .background = sc.bg,
        .text = sc.ink,
        .text_muted = sc.muted,
        .accent = sc.accent,
        .focus_ring = sc.accent,
        .scrim = sc.overlay,
        .border = sc.soft_border,
        .surface = sc.field,
        .surface_subtle = sc.field,
        .surface_pressed = sc.field,
    } };
}

// tokens_fn: consulted on every install and rebuild. Base house pack in the
// active scheme, then the station colors layered on top.
pub fn tokensFn(model: *const model_mod.Model) canvas.DesignTokens {
    const scheme: canvas.ColorScheme = switch (model.theme_scheme) {
        .light => .light,
        .dark => .dark,
    };
    const base = canvas.DesignTokens.theme(.{ .color_scheme = scheme, .density = .regular });
    return base.withOverrides(stationOverrides(model.station_colors));
}
