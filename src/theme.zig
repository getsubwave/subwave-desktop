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

// House overrides that are ours, not the station's: the same on every theme,
// so they layer under the station colors rather than travelling with them.
//
// `blur.scrim = 0` kills the modal scrim's backdrop blur. The design brief
// bans blur outright, so this only ever painted a frosted edge nobody asked
// for — but on Linux it also cost the app its interactivity. The GTK host
// wires no GPU packet path (platform/linux/root.zig only exports
// presentGpuSurfacePixels), so every Linux frame is rasterized on the CPU by
// ReferenceRenderSurface, and `drawBlur` is by the SDK's own admission "the
// renderer's most expensive command — an O(kernel²) Gaussian gather per
// output pixel over what is usually the whole viewport". At a 1133x564 window
// on a 1.67 desktop scale that is 1.77M pixels x a 15x15 kernel, ~400M
// weighted samples, every frame the backdrop changes — and with the spectrum
// visualizer animating behind the sheet at ~25Hz it changes constantly, so
// the renderer's memo (keyed on the destination pixels) misses every time.
// Measured with `native automate profile on`: present p90 571ms and input
// latency 580ms with the back panel open, against 17ms with it closed
// (issue #36). Dropping the blur takes that to 74ms.
const house_overrides: canvas.DesignTokenOverrides = .{ .blur = .{ .scrim = 0 } };

// tokens_fn: consulted on every install and rebuild. Base house pack in the
// active scheme, then the station colors layered on top.
pub fn tokensFn(model: *const model_mod.Model) canvas.DesignTokens {
    const scheme: canvas.ColorScheme = switch (model.theme_scheme) {
        .light => .light,
        .dark => .dark,
    };
    const base = canvas.DesignTokens.theme(.{ .color_scheme = scheme, .density = .regular });
    return base.withOverrides(house_overrides).withOverrides(stationOverrides(model.station_colors));
}

// ------------------------------------------------------------------- tests
const std = @import("std");
const testing = std.testing;

test "no scheme leaves the modal scrim's backdrop blur armed" {
    // The blur is the Linux CPU rasterizer's most expensive command and the
    // design brief bans blur anyway; a station theme must not be able to
    // bring it back. See `house_overrides` (issue #36).
    inline for (.{ color.Scheme.light, color.Scheme.dark }) |scheme| {
        const m: model_mod.Model = .{
            .theme_scheme = scheme,
            .station_colors = color.defaults(scheme),
        };
        const tokens = tokensFn(&m);
        try testing.expectEqual(@as(f32, 0), tokens.blur.scrim);
        // The wash survives: the modal still dims what is behind it.
        try testing.expect(tokens.colors.scrim.a > 0);
    }
}
