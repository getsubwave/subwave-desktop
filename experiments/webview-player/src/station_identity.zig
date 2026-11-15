//! Canonical, credential-free identity for a station origin plus base path.
const std = @import("std");

pub const max_base_bytes: usize = 256;
pub const max_input_bytes: usize = 1024;

pub const StationIdentity = struct {
    base_storage: [max_base_bytes]u8 = undefined,
    base_len: u16 = 0,
    id: [64]u8 = undefined,

    pub fn base(self: *const StationIdentity) []const u8 {
        return self.base_storage[0..self.base_len];
    }
};

pub const NormalizeError = error{
    EmptyStation,
    InputTooLong,
    CanonicalBaseTooLong,
    ControlCharacter,
    InvalidScheme,
    InvalidAuthority,
    UserInfoForbidden,
    QueryOrFragmentForbidden,
    BackslashForbidden,
    InvalidHost,
    InvalidPort,
    InvalidPath,
    DotSegmentForbidden,
    EncodedSeparatorForbidden,
};

/// Writes a fully owned identity. Callers may copy or move the struct safely:
/// it contains lengths into its own arrays, never self-referential slices.
pub fn normalizeStation(raw: []const u8, output: *StationIdentity) NormalizeError!*const StationIdentity {
    if (raw.len > max_input_bytes) return error.InputTooLong;
    const input = std.mem.trim(u8, raw, " \t\r\n\x0b\x0c");
    if (input.len == 0) return error.EmptyStation;
    for (input) |byte| {
        if (byte < 0x20 or byte == 0x7f) return error.ControlCharacter;
        if (byte == '\\') return error.BackslashForbidden;
    }
    if (std.mem.findAny(u8, input, "?#") != null) return error.QueryOrFragmentForbidden;

    var scheme: []const u8 = "https";
    var remainder = input;
    if (std.mem.find(u8, input, "://")) |at| {
        const candidate = input[0..at];
        if (std.ascii.eqlIgnoreCase(candidate, "http")) scheme = "http" else if (std.ascii.eqlIgnoreCase(candidate, "https")) scheme = "https" else return error.InvalidScheme;
        remainder = input[at + 3 ..];
    } else if (input[0] != '[') {
        if (std.mem.findScalar(u8, input, ':')) |colon| {
            // A colon before the first slash is either a numeric port or an
            // unsupported URI scheme such as javascript:.
            const first_slash = std.mem.findScalar(u8, input, '/') orelse input.len;
            if (colon < first_slash and !allDigits(input[colon + 1 .. first_slash])) return error.InvalidScheme;
        }
    }

    const slash = std.mem.findScalar(u8, remainder, '/') orelse remainder.len;
    const authority = remainder[0..slash];
    var path = remainder[slash..];
    if (authority.len == 0) return error.InvalidAuthority;
    if (std.mem.findScalar(u8, authority, '@') != null) return error.UserInfoForbidden;

    var host: []const u8 = undefined;
    var port_text: ?[]const u8 = null;
    var ipv6 = false;
    if (authority[0] == '[') {
        const close = std.mem.findScalar(u8, authority, ']') orelse return error.InvalidHost;
        if (close == 1) return error.InvalidHost;
        host = authority[1..close];
        ipv6 = true;
        if (close + 1 < authority.len) {
            if (authority[close + 1] != ':') return error.InvalidAuthority;
            port_text = authority[close + 2 ..];
        }
        _ = std.Io.net.IpAddress.parseIp6(host, 0) catch return error.InvalidHost;
    } else {
        if (std.mem.findScalar(u8, authority, ':')) |colon| {
            if (std.mem.findScalarPos(u8, authority, colon + 1, ':') != null) return error.InvalidHost;
            host = authority[0..colon];
            port_text = authority[colon + 1 ..];
        } else host = authority;
        try validateDnsOrIpv4(host);
    }
    if (host.len == 0) return error.InvalidHost;

    var port: ?u16 = null;
    if (port_text) |text| {
        if (text.len == 0 or !allDigits(text)) return error.InvalidPort;
        const parsed = std.fmt.parseInt(u16, text, 10) catch return error.InvalidPort;
        if (parsed == 0) return error.InvalidPort;
        if (!((std.mem.eql(u8, scheme, "https") and parsed == 443) or (std.mem.eql(u8, scheme, "http") and parsed == 80))) port = parsed;
    }

    while (path.len > 0 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
    var writer = std.Io.Writer.fixed(&output.base_storage);
    writer.print("{s}://", .{scheme}) catch return error.CanonicalBaseTooLong;
    if (ipv6) {
        const address = std.Io.net.IpAddress.parseIp6(host, 0) catch unreachable;
        var address_storage: [64]u8 = undefined;
        var address_writer = std.Io.Writer.fixed(&address_storage);
        address.format(&address_writer) catch return error.InvalidHost;
        const formatted = address_writer.buffered();
        // IpAddress formatting includes the zero port; retain only [address].
        const end = std.mem.lastIndexOfScalar(u8, formatted, ':') orelse return error.InvalidHost;
        writer.writeAll(formatted[0..end]) catch return error.CanonicalBaseTooLong;
    } else {
        for (host) |byte| writer.writeByte(std.ascii.toLower(byte)) catch return error.CanonicalBaseTooLong;
    }
    if (port) |value| writer.print(":{d}", .{value}) catch return error.CanonicalBaseTooLong;
    try writeCanonicalPath(path, &writer);
    const canonical = writer.buffered();
    output.base_len = @intCast(canonical.len);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical, &digest, .{});
    _ = std.fmt.bufPrint(&output.id, "{x}", .{digest}) catch unreachable;
    return output;
}

fn allDigits(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn validateDnsOrIpv4(host: []const u8) NormalizeError!void {
    if (host.len == 0 or host.len > 253 or host[0] == '.' or host[host.len - 1] == '.') return error.InvalidHost;
    var labels = std.mem.splitScalar(u8, host, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or label[0] == '-' or label[label.len - 1] == '-') return error.InvalidHost;
        for (label) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '-')) return error.InvalidHost;
    }
    // libc accepts several legacy numeric IPv4 spellings (one-part hex,
    // shortened dotted forms, and mixed decimal/hex). They are ambiguous
    // station identities because the network resolves them as an address
    // while a URL normalizer can preserve them as DNS text. Reject any host
    // made entirely of decimal or 0x-prefixed numeric labels. A clear DNS
    // suffix such as `123.example` or `deadbeef.com` remains valid.
    if (numericIpv4Looking(host)) {
        _ = std.Io.net.IpAddress.parseIp4(host, 0) catch return error.InvalidHost;
    }
}

fn numericIpv4Looking(host: []const u8) bool {
    var labels = std.mem.splitScalar(u8, host, '.');
    var count: usize = 0;
    while (labels.next()) |label| {
        count += 1;
        if (label.len == 0) return false;
        if (label.len > 2 and label[0] == '0' and (label[1] == 'x' or label[1] == 'X')) {
            for (label[2..]) |byte| if (hexNibble(byte) == null) return false;
        } else {
            for (label) |byte| if (!std.ascii.isDigit(byte)) return false;
        }
    }
    return count >= 1 and count <= 4;
}

fn hexNibble(byte: u8) ?u8 {
    return if (byte >= '0' and byte <= '9') byte - '0' else if (byte >= 'a' and byte <= 'f') byte - 'a' + 10 else if (byte >= 'A' and byte <= 'F') byte - 'A' + 10 else null;
}

fn unreserved(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~';
}

fn writeCanonicalPath(path: []const u8, writer: *std.Io.Writer) NormalizeError!void {
    if (path.len == 0) return;
    if (path[0] != '/') return error.InvalidPath;
    writer.writeByte('/') catch return error.CanonicalBaseTooLong;
    var segment_start: usize = 1;
    var i: usize = 1;
    while (i < path.len) {
        const byte = path[i];
        if (byte >= 0x80 or byte == ' ') return error.InvalidPath;
        if (byte == '/') {
            try rejectDotSegment(path[segment_start..i]);
            segment_start = i + 1;
            writer.writeByte('/') catch return error.CanonicalBaseTooLong;
            i += 1;
            continue;
        }
        if (byte == '%') {
            if (i + 2 >= path.len) return error.InvalidPath;
            const high = hexNibble(path[i + 1]) orelse return error.InvalidPath;
            const low = hexNibble(path[i + 2]) orelse return error.InvalidPath;
            const decoded = high * 16 + low;
            if (decoded == '/' or decoded == '\\' or decoded == '%') return error.EncodedSeparatorForbidden;
            if (unreserved(decoded)) writer.writeByte(decoded) catch return error.CanonicalBaseTooLong else {
                const upper = "0123456789ABCDEF";
                writer.writeAll(&.{ '%', upper[high], upper[low] }) catch return error.CanonicalBaseTooLong;
            }
            i += 3;
            continue;
        }
        writer.writeByte(byte) catch return error.CanonicalBaseTooLong;
        i += 1;
    }
    try rejectDotSegment(path[segment_start..]);
    // Percent-decoded unreserved dots may have formed a segment in output;
    // validate the canonical result as well.
    const canonical = writer.buffered();
    var segments = std.mem.splitScalar(u8, canonical, '/');
    while (segments.next()) |segment| if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.DotSegmentForbidden;
}

fn rejectDotSegment(segment: []const u8) NormalizeError!void {
    if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.DotSegmentForbidden;
}

fn expectBase(raw: []const u8, expected: []const u8) !void {
    var identity: StationIdentity = .{};
    _ = try normalizeStation(raw, &identity);
    try std.testing.expectEqualStrings(expected, identity.base());
}

test "normalizes bare hosts, case, default ports, IPv6, and base paths" {
    try expectBase(" RADIO.EXAMPLE:443/ ", "https://radio.example");
    try expectBase("HTTP://Radio.Example:80/", "http://radio.example");
    try expectBase("http://[0:0:0:0:0:0:0:1]:43127/", "http://[::1]:43127");
    try expectBase("[::1]:443/", "https://[::1]");
    try expectBase("https://radio.example/player/", "https://radio.example/player");
    try expectBase("radio.example:8443/player///", "https://radio.example:8443/player");
    try expectBase("radio.example:00443", "https://radio.example");
}

test "stable id hashes only the canonical credential-free base" {
    var a: StationIdentity = .{};
    var b: StationIdentity = .{};
    _ = try normalizeStation("HTTPS://RADIO.EXAMPLE:443/", &a);
    _ = try normalizeStation("radio.example", &b);
    try std.testing.expectEqualStrings(&a.id, &b.id);
    try std.testing.expectEqual(@as(usize, 64), a.id.len);
    try std.testing.expectEqualStrings("c0d7a624da05a948af4d802d268199ab8f37a7591f503432821dd738cb82a785", &a.id);
}

test "rejects credentials, unsafe syntax, controls, schemes, and bounds" {
    const cases = .{
        .{ "https://u:p@radio.example", error.UserInfoForbidden },
        .{ "javascript:alert(1)", error.InvalidScheme },
        .{ "ftp://radio.example", error.InvalidScheme },
        .{ "https://radio.example?q=1", error.QueryOrFragmentForbidden },
        .{ "https://radio.example/#x", error.QueryOrFragmentForbidden },
        .{ "https://radio.example\\path", error.BackslashForbidden },
        .{ "https://radio.example/pa\nth", error.ControlCharacter },
        .{ "https://-radio.example", error.InvalidHost },
        .{ "https://radio.example:0", error.InvalidPort },
    };
    inline for (cases) |case| {
        var identity: StationIdentity = .{};
        try std.testing.expectError(case[1], normalizeStation(case[0], &identity));
    }
    var overlong: [max_input_bytes + 1]u8 = @splat('a');
    var identity: StationIdentity = .{};
    try std.testing.expectError(error.InputTooLong, normalizeStation(&overlong, &identity));
    var long_path: [max_base_bytes + 20]u8 = @splat('a');
    @memcpy(long_path[0..22], "https://radio.example/");
    try std.testing.expectError(error.CanonicalBaseTooLong, normalizeStation(&long_path, &identity));
}

test "rejects legacy numeric IP and encoded authority ambiguity" {
    const cases = .{
        "http://0x7f000001",
        "http://0x7f.1",
        "http://127.0.0x1",
        "http://0177.0.0.1",
        "https://radio%2eexample",
        "https://%31%32%37.0.0.1",
        "https://radió.example",
        "https://radio.example:%34%34%33",
        "https://[fe80::1%25lo0]",
        "https://[::1]garbage",
    };
    inline for (cases) |raw| {
        var identity: StationIdentity = .{};
        try std.testing.expectError(if (std.mem.indexOf(u8, raw, "]garbage") != null) error.InvalidAuthority else if (std.mem.indexOf(u8, raw, ":%") != null) error.InvalidPort else error.InvalidHost, normalizeStation(raw, &identity));
    }
    try expectBase("https://123.example", "https://123.example");
    try expectBase("https://deadbeef.com", "https://deadbeef.com");
}

test "rejects direct, encoded, mixed-case, and double-escaped path traversal" {
    const paths = .{
        "https://radio.example/./player",
        "https://radio.example/a/../player",
        "https://radio.example/%2e/player",
        "https://radio.example/%2E%2e/player",
        "https://radio.example/a%2fb",
        "https://radio.example/a%2Fb",
        "https://radio.example/a%5cb",
        "https://radio.example/a%25%32%66b",
    };
    inline for (paths) |raw| {
        var identity: StationIdentity = .{};
        try std.testing.expectError(if (std.mem.indexOf(u8, raw, "%2e") != null or std.mem.indexOf(u8, raw, "%2E") != null or std.mem.indexOf(u8, raw, "/./") != null or std.mem.indexOf(u8, raw, "/../") != null) error.DotSegmentForbidden else error.EncodedSeparatorForbidden, normalizeStation(raw, &identity));
    }
}

test "canonicalizes safe percent escapes and owned values survive copies" {
    var original: StationIdentity = .{};
    _ = try normalizeStation("https://RADIO.example/show/%7eDJ/%3a", &original);
    var copied = original;
    @memset(&original.base_storage, 0);
    try std.testing.expectEqualStrings("https://radio.example/show/~DJ/%3A", copied.base());
}
