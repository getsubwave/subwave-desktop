//! UTF-8-safe truncation for the fixed buffers the model copies text into.
//! Station text arrives as valid UTF-8 (std.json validates it); these only
//! keep a byte bound from splitting a code point.
const std = @import("std");

/// The longest prefix of `text` within `limit` bytes that ends on a code
/// point boundary.
pub fn prefix(text: []const u8, limit: usize) []const u8 {
    var n = @min(text.len, limit);
    while (n > 0 and n < text.len and text[n] & 0xC0 == 0x80) n -= 1;
    return text[0..n];
}

/// Copies `prefix(text, buf.len)` into `buf`; the result aliases `buf`.
pub fn copyInto(buf: []u8, text: []const u8) []const u8 {
    const kept = prefix(text, buf.len);
    @memcpy(buf[0..kept.len], kept);
    return buf[0..kept.len];
}

/// `bytes` without a trailing code point that a full fixed writer cut short.
pub fn dropCutTail(bytes: []const u8) []const u8 {
    var start = bytes.len;
    while (start > 0 and bytes.len - start < 3 and bytes[start - 1] & 0xC0 == 0x80) start -= 1;
    if (start == 0) return bytes[0..0];
    const lead = bytes[start - 1];
    const width: usize = if (lead < 0x80) 1 else if (lead & 0xE0 == 0xC0) 2 else if (lead & 0xF0 == 0xE0) 3 else if (lead & 0xF8 == 0xF0) 4 else 1;
    return if (bytes.len - (start - 1) < width) bytes[0 .. start - 1] else bytes;
}

const testing = std.testing;

test "prefix and copyInto never split a code point" {
    try testing.expectEqualStrings("ab", prefix("abé", 3));
    try testing.expectEqualStrings("abé", prefix("abé", 4));
    try testing.expectEqualStrings("abé", prefix("abé", 9));
    var buf: [3]u8 = undefined;
    try testing.expectEqualStrings("ab", copyInto(&buf, "abé"));
}

test "dropCutTail removes only an incomplete final code point" {
    const word = "Jó—"; // 'ó' is 2 bytes, '—' is 3
    try testing.expectEqualStrings(word, dropCutTail(word));
    try testing.expectEqualStrings("Jó", dropCutTail(word[0 .. word.len - 1]));
    try testing.expectEqualStrings("Jó", dropCutTail(word[0 .. word.len - 2]));
    try testing.expectEqualStrings("J", dropCutTail(word[0..2]));
    try testing.expectEqualStrings("", dropCutTail(""));
}
