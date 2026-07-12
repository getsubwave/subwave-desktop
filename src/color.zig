//! Station-theme color resolver: turns the 7 CSS token strings from /api/themes
//! (hex, rgb()/rgba(), oklch(), color-mix(in oklab, …)) into canvas.Color.
//! Pure, no I/O — pinned by the tests at the bottom (`native test`).
//!
//! The station's default themes use oklch for accent and color-mix(in oklab)
//! for the field surface, so we implement the real OKLab/OKLCH math (Björn
//! Ottosson) rather than only falling back like the RN app does.

const std = @import("std");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;

pub const Scheme = enum { light, dark };

pub const StationColors = struct {
    bg: canvas.Color,
    ink: canvas.Color,
    muted: canvas.Color,
    accent: canvas.Color,
    overlay: canvas.Color,
    soft_border: canvas.Color,
    field: canvas.Color,
};

// Mode-aware fallbacks (mirror app/src/theme/ThemeContext.tsx LIGHT/DARK
// defaults) — used only when a token string fails to resolve, and never
// falling a light token back to a dark default.
pub fn defaults(scheme: Scheme) StationColors {
    return switch (scheme) {
        .light => .{
            .bg = hex("#f3efe6").?,
            .ink = hex("#161412").?,
            .muted = hex("#7a736a").?,
            .accent = hex("#c0392b").?,
            .overlay = canvas.Color.rgba(0, 0, 0, 0.05),
            .soft_border = canvas.Color.rgba(0, 0, 0, 0.08),
            .field = hex("#e7e1d4").?,
        },
        .dark => .{
            .bg = hex("#100e0c").?,
            .ink = hex("#ece6dc").?,
            .muted = hex("#c1c0bd").?,
            .accent = hex("#e0524a").?,
            .overlay = canvas.Color.rgba(0, 0, 0, 0.55),
            .soft_border = canvas.Color.rgba(1, 1, 1, 0.1),
            .field = hex("#1b1815").?,
        },
    };
}

// Resolve one token string, or null when it isn't a form we understand.
pub fn resolve(value: []const u8) ?canvas.Color {
    const v = std.mem.trim(u8, value, " \t\r\n");
    if (v.len == 0) return null;
    if (v[0] == '#') return hex(v);
    if (std.mem.startsWith(u8, v, "rgb")) return rgb(v);
    if (std.mem.startsWith(u8, v, "oklch")) return oklch(v);
    if (std.mem.startsWith(u8, v, "color-mix")) return colorMix(v);
    return null;
}

// Resolve `value`, or `fb` when it can't be understood.
pub fn resolveOr(value: []const u8, fb: canvas.Color) canvas.Color {
    return resolve(value) orelse fb;
}

// ------------------------------------------------------------------ hex
fn nib(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

pub fn hex(v: []const u8) ?canvas.Color {
    if (v.len == 0 or v[0] != '#') return null;
    const h = v[1..];
    var r: u8 = 0;
    var g: u8 = 0;
    var b: u8 = 0;
    var a: u8 = 255;
    switch (h.len) {
        3, 4 => {
            const rr = nib(h[0]) orelse return null;
            const gg = nib(h[1]) orelse return null;
            const bb = nib(h[2]) orelse return null;
            r = rr * 17;
            g = gg * 17;
            b = bb * 17;
            if (h.len == 4) a = (nib(h[3]) orelse return null) * 17;
        },
        6, 8 => {
            r = (nib(h[0]) orelse return null) * 16 + (nib(h[1]) orelse return null);
            g = (nib(h[2]) orelse return null) * 16 + (nib(h[3]) orelse return null);
            b = (nib(h[4]) orelse return null) * 16 + (nib(h[5]) orelse return null);
            if (h.len == 8) a = (nib(h[6]) orelse return null) * 16 + (nib(h[7]) orelse return null);
        },
        else => return null,
    }
    return canvas.Color.rgba8(r, g, b, a);
}

// ------------------------------------------------------------- rgb/rgba
fn inner(v: []const u8) ?[]const u8 {
    const lp = std.mem.indexOfScalar(u8, v, '(') orelse return null;
    const rp = std.mem.lastIndexOfScalar(u8, v, ')') orelse return null;
    if (rp <= lp + 1) return null;
    return v[lp + 1 .. rp];
}

fn rgb(v: []const u8) ?canvas.Color {
    const body = inner(v) orelse return null;
    var it = std.mem.tokenizeAny(u8, body, ", \t");
    const rs = it.next() orelse return null;
    const gs = it.next() orelse return null;
    const bs = it.next() orelse return null;
    const r = std.fmt.parseFloat(f64, rs) catch return null;
    const g = std.fmt.parseFloat(f64, gs) catch return null;
    const b = std.fmt.parseFloat(f64, bs) catch return null;
    var a: f64 = 1.0;
    if (it.next()) |as| a = std.fmt.parseFloat(f64, as) catch 1.0;
    return canvas.Color.rgba(f32c(r / 255.0), f32c(g / 255.0), f32c(b / 255.0), f32c(a));
}

// ---------------------------------------------------------------- oklch
fn oklch(v: []const u8) ?canvas.Color {
    const body = inner(v) orelse return null;
    // "L C H" optionally "L C H / a"
    var alpha: f64 = 1.0;
    var core = body;
    if (std.mem.indexOfScalar(u8, body, '/')) |slash| {
        core = body[0..slash];
        alpha = std.fmt.parseFloat(f64, std.mem.trim(u8, body[slash + 1 ..], " \t")) catch 1.0;
    }
    var it = std.mem.tokenizeAny(u8, core, " \t");
    const l = std.fmt.parseFloat(f64, it.next() orelse return null) catch return null;
    const c = std.fmt.parseFloat(f64, it.next() orelse return null) catch return null;
    const h = std.fmt.parseFloat(f64, it.next() orelse return null) catch return null;
    const hr = h * std.math.pi / 180.0;
    const lab = Lab{ .l = l, .a = c * std.math.cos(hr), .b = c * std.math.sin(hr) };
    return labToColor(lab, alpha);
}

// ------------------------------------------------------------- color-mix
// color-mix(in <space>, C1 [p1%], C2 [p2%]) — we mix in OKLab regardless of the
// named space (the station only ever uses oklab), which is perceptually even.
fn colorMix(v: []const u8) ?canvas.Color {
    const body = inner(v) orelse return null;
    // Drop the leading "in <space>," segment.
    const first_comma = std.mem.indexOfScalar(u8, body, ',') orelse return null;
    const rest = body[first_comma + 1 ..];
    const mid_comma = std.mem.indexOfScalar(u8, rest, ',') orelse return null;
    const a_part = std.mem.trim(u8, rest[0..mid_comma], " \t");
    const b_part = std.mem.trim(u8, rest[mid_comma + 1 ..], " \t");

    var wa: f64 = -1;
    var wb: f64 = -1;
    const ca = splitPct(a_part, &wa) orelse return null;
    const cb = splitPct(b_part, &wb) orelse return null;
    // Percentage normalization: both omitted → 50/50; one omitted → remainder.
    if (wa < 0 and wb < 0) {
        wa = 0.5;
        wb = 0.5;
    } else if (wa < 0) {
        wa = 1.0 - wb;
    } else if (wb < 0) {
        wb = 1.0 - wa;
    } else {
        const sum = wa + wb;
        if (sum > 0) {
            wa /= sum;
            wb /= sum;
        }
    }
    const col_a = resolve(ca) orelse return null;
    const col_b = resolve(cb) orelse return null;
    const la = colorToLab(col_a);
    const lb = colorToLab(col_b);
    const mixed = Lab{
        .l = la.l * wa + lb.l * wb,
        .a = la.a * wa + lb.a * wb,
        .b = la.b * wa + lb.b * wb,
    };
    const alpha = @as(f64, col_a.a) * wa + @as(f64, col_b.a) * wb;
    return labToColor(mixed, alpha);
}

// Split "…color… 92%" into the color string and a 0..1 weight (weight stays -1
// when no percentage is present).
fn splitPct(part: []const u8, w: *f64) ?[]const u8 {
    if (std.mem.lastIndexOfScalar(u8, part, '%')) |pct| {
        // The token before '%' is the number; everything before it is the color.
        var i = pct;
        while (i > 0 and (std.ascii.isDigit(part[i - 1]) or part[i - 1] == '.')) i -= 1;
        const num = part[i..pct];
        const col = std.mem.trim(u8, part[0..i], " \t");
        if (col.len == 0) return null;
        w.* = (std.fmt.parseFloat(f64, num) catch return null) / 100.0;
        return col;
    }
    return std.mem.trim(u8, part, " \t");
}

// -------------------------------------------------------- OKLab plumbing
const Lab = struct { l: f64, a: f64, b: f64 };

fn f32c(x: f64) f32 {
    return @floatCast(std.math.clamp(x, 0.0, 1.0));
}

fn srgbToLinear(c: f64) f64 {
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
}
fn linearToSrgb(c: f64) f64 {
    const x = std.math.clamp(c, 0.0, 1.0);
    return if (x <= 0.0031308) 12.92 * x else 1.055 * std.math.pow(f64, x, 1.0 / 2.4) - 0.055;
}

fn linearToLab(r: f64, g: f64, b: f64) Lab {
    const l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b;
    const m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b;
    const s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b;
    const l_ = std.math.cbrt(l);
    const m_ = std.math.cbrt(m);
    const s_ = std.math.cbrt(s);
    return .{
        .l = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
        .a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
        .b = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_,
    };
}

fn labToLinear(lab: Lab) [3]f64 {
    const l_ = lab.l + 0.3963377774 * lab.a + 0.2158037573 * lab.b;
    const m_ = lab.l - 0.1055613458 * lab.a - 0.0638541728 * lab.b;
    const s_ = lab.l - 0.0894841775 * lab.a - 1.2914855480 * lab.b;
    const l = l_ * l_ * l_;
    const m = m_ * m_ * m_;
    const s = s_ * s_ * s_;
    return .{
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    };
}

fn colorToLab(c: canvas.Color) Lab {
    return linearToLab(srgbToLinear(c.r), srgbToLinear(c.g), srgbToLinear(c.b));
}

fn labToColor(lab: Lab, alpha: f64) canvas.Color {
    const lin = labToLinear(lab);
    return canvas.Color.rgba(
        f32c(linearToSrgb(lin[0])),
        f32c(linearToSrgb(lin[1])),
        f32c(linearToSrgb(lin[2])),
        f32c(alpha),
    );
}

// -------------------------------------------------------------- tests
const testing = std.testing;

fn approx(a: f32, b: f32) bool {
    return @abs(a - b) < 0.02;
}

test "hex resolves exactly" {
    const c = resolve("#f3efe6").?;
    try testing.expect(approx(c.r, 243.0 / 255.0));
    try testing.expect(approx(c.g, 239.0 / 255.0));
    try testing.expect(approx(c.b, 230.0 / 255.0));
    try testing.expect(approx(c.a, 1.0));
}

test "rgba resolves channels + alpha" {
    const c = resolve("rgba(0, 0, 0, 0.05)").?;
    try testing.expect(approx(c.r, 0));
    try testing.expect(approx(c.a, 0.05));
    const w = resolve("rgba(255, 255, 255, 0.1)").?;
    try testing.expect(approx(w.r, 1.0));
    try testing.expect(approx(w.a, 0.1));
}

test "oklch accent is a saturated red" {
    // classic-light --accent = oklch(0.62 0.22 25)
    const c = resolve("oklch(0.62 0.22 25)").?;
    try testing.expect(c.r > c.g and c.r > c.b); // red dominant
    try testing.expect(c.r > 0.6); // vivid
    try testing.expect(c.r <= 1.0 and c.g >= 0.0 and c.b >= 0.0); // in gamut
}

test "color-mix in oklab lands between the two inputs" {
    // classic-light --field = color-mix(in oklab, #f3efe6 92%, #161412)
    const c = resolve("color-mix(in oklab, #f3efe6 92%, #161412)").?;
    const bg = resolve("#f3efe6").?;
    // 92% toward the light bg → close to bg but slightly darker
    try testing.expect(c.r < bg.r and c.r > 0.7);
    try testing.expect(c.a > 0.99);
}

test "unknown forms return null; resolveOr uses the fallback" {
    try testing.expect(resolve("chartreuse") == null);
    try testing.expect(resolve("") == null);
    const fb = canvas.Color.rgb8(1, 2, 3);
    const c = resolveOr("nope", fb);
    try testing.expect(approx(c.r, 1.0 / 255.0));
}
