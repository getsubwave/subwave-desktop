//! Spectrum-analyzer ballistics. The platform delivers 32 band magnitudes on
//! each `.spectrum` audio event (~25 Hz), each byte a 0..255 linear-in-dB
//! level. Classic analyzer motion: bars attack instantly and decay linearly —
//! so a transient snaps up and eases back, and a pause freezes on real data.
//! Pure + tested; the ~25 Hz spectrum cadence is the animation clock (no
//! separate frame timer needed).

const std = @import("std");

pub const band_count = 32;

// Advance displayed `levels` toward the incoming `bands` (0..255 → 0..1):
// rising bands jump to the new value, falling bands ease down by `decay`
// per step but never below the current target.
pub fn step(levels: []f32, bands: []const u8, decay: f32) void {
    const n = @min(levels.len, bands.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const t = @as(f32, @floatFromInt(bands[i])) / 255.0;
        if (t >= levels[i]) {
            levels[i] = t; // instant attack
        } else {
            levels[i] = @max(t, levels[i] - decay); // linear decay toward target
        }
    }
}

const testing = std.testing;
fn approx(a: f32, b: f32) bool {
    return @abs(a - b) < 0.001;
}

test "rising band attacks instantly" {
    var levels = [_]f32{0} ** 4;
    const bands = [_]u8{ 255, 128, 0, 0 };
    step(&levels, &bands, 0.1);
    try testing.expect(approx(levels[0], 1.0));
    try testing.expect(approx(levels[1], 128.0 / 255.0));
    try testing.expect(approx(levels[2], 0.0));
}

test "falling band decays linearly toward the target" {
    var levels = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
    const zero = [_]u8{ 0, 0, 0, 0 };
    step(&levels, &zero, 0.1);
    try testing.expect(approx(levels[0], 0.9)); // one linear step down
    step(&levels, &zero, 0.1);
    try testing.expect(approx(levels[0], 0.8));
    // never overshoots below the target
    const half = [_]u8{ 128, 128, 128, 128 };
    var l2 = [_]f32{ 0.5, 0.5, 0.5, 0.5 }; // target 128/255 ≈ 0.502 > 0.5 → attack
    step(&l2, &half, 0.1);
    try testing.expect(approx(l2[0], 128.0 / 255.0));
}
