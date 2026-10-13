//! The one ISO-8601 timestamp parser. Station stamps come from JavaScript's
//! `toISOString()` (always `Z`), but the parser also takes `±hh:mm` offsets
//! and reads a zone-less stamp as UTC, the controller's clock.
const std = @import("std");

/// Epoch milliseconds for `YYYY-MM-DDTHH:MM:SS[.fff…][Z|±hh:mm]`, or null.
/// Fractions keep millisecond precision; extra digits are ignored.
pub fn parseMs(value: []const u8) ?i64 {
    if (value.len < 19 or value[4] != '-' or value[7] != '-' or value[10] != 'T' or value[13] != ':' or value[16] != ':') return null;
    const year = digits(value[0..4]) orelse return null;
    const month = digits(value[5..7]) orelse return null;
    const day = digits(value[8..10]) orelse return null;
    const hour = digits(value[11..13]) orelse return null;
    const minute = digits(value[14..16]) orelse return null;
    const second = digits(value[17..19]) orelse return null;
    if (month < 1 or month > 12 or day < 1 or hour > 23 or minute > 59 or second > 59) return null;
    const leap = @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
    const month_days = [_]i64{ 31, if (leap) @as(i64, 29) else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (day > month_days[@intCast(month - 1)]) return null;
    var at: usize = 19;
    var fraction: i64 = 0;
    if (at < value.len and value[at] == '.') {
        at += 1;
        const begin = at;
        while (at < value.len and std.ascii.isDigit(value[at])) : (at += 1) {
            if (at - begin < 3) fraction = fraction * 10 + value[at] - '0';
        }
        if (at == begin) return null;
        if (at - begin == 1) fraction *= 100;
        if (at - begin == 2) fraction *= 10;
    }
    var offset: i64 = 0;
    if (at == value.len or (value[at] == 'Z' and at + 1 == value.len)) {} else if ((value[at] == '+' or value[at] == '-') and at + 6 == value.len and value[at + 3] == ':') {
        const hours = digits(value[at + 1 .. at + 3]) orelse return null;
        const minutes = digits(value[at + 4 .. at + 6]) orelse return null;
        if (hours > 23 or minutes > 59) return null;
        offset = (hours * 60 + minutes) * 60;
        if (value[at] == '-') offset = -offset;
    } else return null;
    // Days from the civil date (Howard Hinnant's algorithm), March-based year.
    const adjusted_year = year - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(adjusted_year, 400);
    const yoe = adjusted_year - era * 400;
    const shifted_month = month + @as(i64, if (month > 2) -3 else 9);
    const doy = @divTrunc(153 * shifted_month + 2, 5) + day - 1;
    const days = era * 146097 + yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy - 719468;
    return (days * 86400 + hour * 3600 + minute * 60 + second - offset) * 1000 + fraction;
}

/// A run of ASCII digits as an integer; null for empty or non-digit input.
pub fn digits(value: []const u8) ?i64 {
    if (value.len == 0) return null;
    for (value) |ch| if (!std.ascii.isDigit(ch)) return null;
    return std.fmt.parseInt(i64, value, 10) catch null;
}

const testing = std.testing;

test "fractions, offsets, zone-less UTC and leap days" {
    try testing.expectEqual(@as(?i64, 0), parseMs("1970-01-01T00:00:00Z"));
    try testing.expectEqual(@as(?i64, -1000), parseMs("1969-12-31T23:59:59Z"));
    try testing.expectEqual(@as(?i64, 123), parseMs("1970-01-01T01:00:00.123+01:00"));
    try testing.expectEqual(@as(?i64, 120), parseMs("1970-01-01T00:00:00.12Z"));
    try testing.expectEqual(@as(?i64, 999), parseMs("1970-01-01T05:30:00.9999+05:30"));
    try testing.expectEqual(parseMs("2026-10-09T12:00:00Z"), parseMs("2026-10-09T07:00:00-05:00"));
    try testing.expectEqual(parseMs("2026-10-09T12:00:00Z"), parseMs("2026-10-09T12:00:00"));
    try testing.expect(parseMs("2024-02-29T12:00:00Z") != null);
}

test "malformed stamps are rejected" {
    inline for (.{ "junk", "2026-02-29T12:00:00Z", "2026-13-01T00:00:00Z", "2026-01-01T24:00:00Z", "2026-01-01T00:00:00.Z", "2026-01-01T00:00:00junk", "2026-01-01T00:00:00+5:30" }) |bad|
        try testing.expect(parseMs(bad) == null);
}

test "digits accepts only non-empty ASCII digit runs" {
    try testing.expectEqual(@as(?i64, 42), digits("42"));
    try testing.expect(digits("") == null);
    try testing.expect(digits("4a") == null);
}
