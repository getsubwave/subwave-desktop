//! Station clocks without a platform timezone database. The public context
//! supplies the local weekday and minute; each poll also picks up DST changes.
const std = @import("std");

pub const Locale = enum { en_gb, en_us };

pub fn locale(value: ?[]const u8) Locale {
    return if (std.mem.eql(u8, value orelse "", "en-US")) .en_us else .en_gb;
}

pub const Parts = struct { day: i64, hour: i64, minute: i64, second: i64 };

pub fn parts(wall_ms: i64, offset_minutes: i64) Parts {
    const seconds = @divFloor(wall_ms, 1000) +| (offset_minutes *| 60);
    return .{
        .day = @mod(@divFloor(seconds, 86400) + 4, 7),
        .hour = @divFloor(@mod(seconds, 86400), 3600),
        .minute = @divFloor(@mod(seconds, 3600), 60),
        .second = @mod(seconds, 60),
    };
}

pub fn offset(wall_ms: i64, hhmm: ?[]const u8, weekday: ?i64) i64 {
    const local_clock = hhmm orelse return 0;
    const day = weekday orelse return 0;
    if (local_clock.len != 5 or local_clock[2] != ':' or day < 0 or day > 6) return 0;
    const h = digits(local_clock[0..2]) orelse return 0;
    const m = digits(local_clock[3..5]) orelse return 0;
    if (h > 23 or m > 59) return 0;
    const utc = parts(wall_ms, 0);
    const delta = @mod((day - utc.day) * 1440 + h * 60 + m - utc.hour * 60 - utc.minute + 5040, 10080) - 5040;
    const rounded = @divFloor(delta + 7, 15) * 15;
    // Reject a stale or malformed context rather than shifting the grid days.
    return if (rounded >= -720 and rounded <= 840) rounded else 0;
}

pub fn clock(buf: []u8, wall_ms: i64, offset_minutes: i64, display_locale: Locale, seconds: bool) []const u8 {
    const p = parts(wall_ms, offset_minutes);
    const h: u64 = @intCast(if (display_locale == .en_us) (if (@mod(p.hour, 12) == 0) @as(i64, 12) else @mod(p.hour, 12)) else p.hour);
    const minute: u64 = @intCast(p.minute);
    const second: u64 = @intCast(p.second);
    const suffix: []const u8 = if (display_locale == .en_us) (if (p.hour < 12) " am" else " pm") else "";
    if (seconds) return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}{s}", .{ h, minute, second, suffix }) catch "";
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}{s}", .{ h, minute, suffix }) catch "";
}

pub fn hourRange(buf: []u8, start: usize, end: usize, display_locale: Locale) []const u8 {
    if (display_locale == .en_gb)
        return std.fmt.bufPrint(buf, "{d:0>2}:00 – {d:0>2}:00", .{ start, end % 24 }) catch "";
    const a = start % 24;
    const b = end % 24;
    return std.fmt.bufPrint(buf, "{d}{s} – {d}{s}", .{
        if (a % 12 == 0) @as(usize, 12) else a % 12,
        if (a < 12) @as([]const u8, "am") else "pm",
        if (b % 12 == 0) @as(usize, 12) else b % 12,
        if (b < 12) @as([]const u8, "am") else "pm",
    }) catch "";
}

pub fn isNow(wall_ms: i64, offset_minutes: i64, day: i64, start: usize, end: usize) bool {
    const p = parts(wall_ms, offset_minutes);
    return day == p.day and p.hour >= start and p.hour < end;
}

fn digits(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(i64, s, 10) catch null;
}

pub fn isoSeconds(s: []const u8) ?i64 {
    if (s.len < 19 or s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':') return null;
    const year = digits(s[0..4]) orelse return null;
    const month = digits(s[5..7]) orelse return null;
    const day = digits(s[8..10]) orelse return null;
    const hour = digits(s[11..13]) orelse return null;
    const minute = digits(s[14..16]) orelse return null;
    const second = digits(s[17..19]) orelse return null;
    if (month < 1 or month > 12 or hour > 23 or minute > 59 or second > 59) return null;
    const leap = @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
    const lengths = [_]i64{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (day < 1 or day > lengths[@intCast(month - 1)]) return null;
    var zone: i64 = 0;
    var pos: usize = 19;
    if (pos < s.len and s[pos] == '.') {
        pos += 1;
        const begin = pos;
        while (pos < s.len and std.ascii.isDigit(s[pos])) : (pos += 1) {}
        if (pos == begin) return null;
    }
    if (pos < s.len) {
        if (s[pos] == 'Z') {
            if (pos + 1 != s.len) return null;
        } else {
            if (s.len - pos != 6 or (s[pos] != '+' and s[pos] != '-') or s[pos + 3] != ':') return null;
            const zh = digits(s[pos + 1 .. pos + 3]) orelse return null;
            const zm = digits(s[pos + 4 ..]) orelse return null;
            if (zh > 23 or zm > 59) return null;
            zone = (zh * 60 + zm) * (if (s[pos] == '-') @as(i64, -1) else 1);
        }
    }
    // Gregorian civil date to days since 1970, also valid before the epoch.
    const y = year - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const yo = y - era * 400;
    const mp = month + @as(i64, if (month > 2) -3 else 9);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const days = era * 146097 + yo * 365 + @divFloor(yo, 4) - @divFloor(yo, 100) + doy - 719468;
    return days * 86400 + hour * 3600 + minute * 60 + second - zone * 60;
}

pub fn timestamp(value: ?std.json.Value) ?i64 {
    const v = value orelse return null;
    return switch (v) {
        .string => isoSeconds(v.string),
        .integer => if (v.integer <= -100_000_000_000 or v.integer >= 100_000_000_000) @divFloor(v.integer, 1000) else v.integer,
        .float => if (std.math.isFinite(v.float) and v.float > -0x1p63 and v.float < 0x1p63)
            timestamp(.{ .integer = @intFromFloat(v.float) })
        else
            null,
        else => null,
    };
}

pub fn playedAt(started: ?[]const u8, t: ?[]const u8, queued: ?[]const u8) ?i64 {
    for ([_]?[]const u8{ started, t, queued }) |s| {
        if (s) |v| if (isoSeconds(v)) |at| return at;
    }
    return null;
}

pub fn ago(buf: []u8, now_ms: i64, at_s: i64) []const u8 {
    const diff = @max(1, @divFloor(now_ms, 1000) -| at_s);
    const unit: []const u8 = if (diff < 60) "s" else if (diff < 3600) "m" else if (diff < 86400) "h" else "d";
    const n = if (diff < 60) diff else if (diff < 3600) @divFloor(diff, 60) else if (diff < 86400) @divFloor(diff, 3600) else @divFloor(diff, 86400);
    return std.fmt.bufPrint(buf, "{d}{s} ago", .{ @as(u64, @intCast(n)), unit }) catch "";
}

const testing = std.testing;

test "offset crosses midnight, week wrap and negative zones" {
    // Sunday 00:10 UTC, then Saturday 23:50 UTC.
    const sun: i64 = 3 * 86400_000 + 10 * 60000;
    try testing.expectEqual(@as(i64, -300), offset(sun, "19:10", 6));
    try testing.expectEqual(@as(i64, 60), offset(sun - 20 * 60000, "00:50", 0));
    try testing.expectEqual(@as(i64, 330), offset(sun, "05:40", 0));
    try testing.expectEqual(@as(i64, 345), offset(sun, "05:55", 0));
    try testing.expectEqual(@as(i64, -720), offset(sun, "12:10", 6));
    try testing.expectEqual(@as(i64, 840), offset(sun, "14:10", 0));
    try testing.expectEqual(@as(i64, 60), offset(sun, "01:09", 0));
    try testing.expectEqual(@as(i64, 120), offset(sun, "02:10", 0));
}

test "missing and invalid clock context falls back to UTC" {
    try testing.expectEqual(@as(i64, 0), offset(0, null, null));
    try testing.expectEqual(@as(i64, 0), offset(0, "00:00", null));
    try testing.expectEqual(@as(i64, 0), offset(0, "24:00", 4));
    try testing.expectEqual(@as(i64, 0), offset(0, "12:60", 4));
    try testing.expectEqual(@as(i64, 0), offset(0, "xx:00", 4));
    try testing.expectEqual(@as(i64, 0), offset(0, "00:00", 8));
    try testing.expectEqual(@as(i64, 0), offset(0, "00:00", 2));
}

test "station clocks, locale and ranges" {
    var buf: [64]u8 = undefined;
    try testing.expectEqual(Locale.en_us, locale("en-US"));
    try testing.expectEqual(Locale.en_gb, locale("fr-FR"));
    try testing.expectEqual(Locale.en_gb, locale(null));
    try testing.expectEqualStrings("00:00", clock(&buf, 0, 0, .en_gb, false));
    try testing.expectEqualStrings("12:00 am", clock(&buf, 0, 0, .en_us, false));
    try testing.expectEqualStrings("12:00:01 pm", clock(&buf, 43201_000, 0, .en_us, true));
    try testing.expectEqualStrings("05:45:00", clock(&buf, 0, 345, .en_gb, true));
    try testing.expectEqualStrings("18:30:00", clock(&buf, 0, -330, .en_gb, true));
    try testing.expectEqualStrings("23:00 – 00:00", hourRange(&buf, 23, 24, .en_gb));
    try testing.expectEqualStrings("11am – 1pm", hourRange(&buf, 11, 13, .en_us));
    try testing.expectEqualStrings("11pm – 12am", hourRange(&buf, 23, 24, .en_us));
    try testing.expectEqual(@as(i64, 3), parts(0, -60).day);
    try testing.expect(isNow(0, -60, 3, 22, 24));
    try testing.expect(!isNow(0, -60, 4, 22, 24));
    try testing.expect(!isNow(0, -60, 3, 20, 23));
}

test "timestamp parsing, offsets, leap dates and history fallback" {
    try testing.expectEqual(@as(?i64, 0), isoSeconds("1970-01-01T00:00:00Z"));
    try testing.expectEqual(@as(?i64, -1), isoSeconds("1969-12-31T23:59:59Z"));
    try testing.expectEqual(@as(?i64, 0), isoSeconds("1970-01-01T05:30:00.999+05:30"));
    try testing.expectEqual(@as(?i64, 0), isoSeconds("1969-12-31T19:00:00-05:00"));
    try testing.expect(isoSeconds("2024-02-29T01:02:03Z") != null);
    for ([_][]const u8{ "2026-02-29T00:00:00Z", "2026-13-01T00:00:00Z", "2026-01-01T25:00:00Z", "2026-01-01T00:00:00junk", "bad" }) |v|
        try testing.expectEqual(@as(?i64, null), isoSeconds(v));
    try testing.expectEqual(@as(?i64, 0), playedAt("bad", "1970-01-01T00:00:00Z", null));
    try testing.expectEqual(@as(?i64, 60), playedAt("1970-01-01T00:01:00Z", "1970-01-01T00:00:00Z", null));
    try testing.expectEqual(@as(?i64, 120), playedAt(null, null, "1970-01-01T00:02:00Z"));
    try testing.expectEqual(@as(?i64, null), playedAt(null, "bad", null));
    try testing.expectEqual(@as(?i64, 1_700_000_000), timestamp(.{ .integer = 1_700_000_000_123 }));
    try testing.expectEqual(@as(?i64, 1_700_000_000), timestamp(.{ .integer = 1_700_000_000 }));
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1s ago", ago(&buf, 0, 30));
    try testing.expectEqualStrings("2m ago", ago(&buf, 120_000, 0));
}
