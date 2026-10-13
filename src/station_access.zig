//! Station identity, bounded preferences and credential snapshots. No I/O.
const std = @import("std");
const builtin = @import("builtin");
const StreamFormat = @import("stream_format.zig").StreamFormat;

pub const max_stations = 9; // eight recents plus the current station
pub const max_base_bytes = 224;
pub const settings_bytes = 32 * 1024;
pub const vault_bytes = 2304; // nine SHA-256 keys + base64-encoded 128-byte passwords
pub const vault_key = "station-passwords-v1";
// SDK 0.10.1's Linux SecretSchema omits libsecret's reserved ABI fields.
// Its first credentialsGet crashes in secret_schema_ref, before any result.
// Keep Linux's existing file persistence until the SDK fixes that adapter.
pub const secure_credentials_supported = builtin.os.tag != .linux;

pub fn hasScheme(raw: []const u8) bool {
    return std.mem.indexOf(u8, raw, "://") != null;
}

pub fn normalizeBase(buf: []u8, raw: []const u8) ![]const u8 {
    const s = std.mem.trimEnd(u8, std.mem.trim(u8, raw, " \t\r\n"), "/");
    if (s.len == 0) return error.EmptyBase;
    for (s) |ch| if (ch <= ' ' or ch == 127 or ch == '\\') return error.InvalidBase;
    var candidate_buf: [256]u8 = undefined;
    const candidate = if (hasScheme(s)) s else try std.fmt.bufPrint(&candidate_buf, "https://{s}", .{s});
    const uri = std.Uri.parse(candidate) catch return error.InvalidBase;
    const https = std.ascii.eqlIgnoreCase(uri.scheme, "https");
    if (!https and !std.ascii.eqlIgnoreCase(uri.scheme, "http")) return error.InvalidBase;
    if (uri.user != null or uri.password != null) return error.StationLoginUnsupported;
    if (uri.host == null or uri.query != null or uri.fragment != null) return error.InvalidBase;
    const authority_start = uri.scheme.len + 3;
    const authority_end = std.mem.indexOfScalarPos(u8, candidate, authority_start, '/') orelse candidate.len;
    var authority = candidate[authority_start..authority_end];
    if (authority.len == 0 or std.mem.indexOfScalar(u8, authority, '%') != null) return error.InvalidBase;
    if ((https and uri.port == 443) or (!https and uri.port == 80)) {
        authority = authority[0..std.mem.lastIndexOfScalar(u8, authority, ':').?];
    }
    const result = try std.fmt.bufPrint(buf, "{s}://{s}{s}", .{ if (https) "https" else "http", authority, candidate[authority_end..] });
    if (result.len > max_base_bytes) return error.InvalidBase;
    const start: usize = if (https) 8 else 7;
    for (buf[start..][0..authority.len]) |*ch| ch.* = std.ascii.toLower(ch.*);
    return result;
}

pub fn isLocalHost(raw_host: []const u8) bool {
    var buf: [256]u8 = undefined;
    if (raw_host.len > buf.len or raw_host.len == 0) return false;
    for (raw_host, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    const h = std.mem.trimEnd(u8, buf[0..raw_host.len], ".");
    if (std.Io.net.Ip4Address.parse(h, 0)) |ip| {
        const b = ip.bytes;
        return b[0] == 127 or b[0] == 10 or (b[0] == 192 and b[1] == 168) or
            (b[0] == 172 and b[1] >= 16 and b[1] <= 31) or (b[0] == 169 and b[1] == 254);
    } else |_| {}
    if (std.mem.indexOfScalar(u8, h, ':') != null) {
        const ip = std.Io.net.Ip6Address.parse(h, 0) catch return false;
        const b = ip.bytes;
        if (std.mem.allEqual(u8, b[0..15], 0) and b[15] == 1) return true;
        if (b[0] & 0xfe == 0xfc or (b[0] == 0xfe and b[1] & 0xc0 == 0x80)) return true;
        if (std.mem.allEqual(u8, b[0..10], 0) and b[10] == 255 and b[11] == 255) {
            var v4_buf: [16]u8 = undefined;
            const v4 = std.fmt.bufPrint(&v4_buf, "{d}.{d}.{d}.{d}", .{ b[12], b[13], b[14], b[15] }) catch return false;
            return isLocalHost(v4);
        }
        return false;
    }
    if (std.mem.eql(u8, h, "localhost") or std.mem.endsWith(u8, h, ".localhost")) return true;
    if (std.mem.indexOfScalar(u8, h, '.') == null) return true;
    for ([_][]const u8{ ".local", ".lan", ".home", ".internal", ".corp", ".intranet", ".localdomain", ".home.arpa" }) |suffix| {
        if (std.mem.endsWith(u8, h, suffix)) return true;
    }
    return false;
}

pub fn needsHttpConsent(base: []const u8) bool {
    if (!std.mem.startsWith(u8, base, "http://")) return false;
    const uri = std.Uri.parse(base) catch return true;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = uri.getHost(&host_buf) catch return true;
    return !isLocalHost(std.mem.trim(u8, host.bytes, "[]"));
}

pub const Entry = struct {
    base_store: [max_base_bytes]u8 = undefined,
    base_len: usize = 0,
    password_store: [128]u8 = undefined,
    password_len: usize = 0,
    format: StreamFormat = .mp3,

    pub fn base(self: *const Entry) []const u8 {
        return self.base_store[0..self.base_len];
    }
    pub fn password(self: *const Entry) []const u8 {
        return self.password_store[0..self.password_len];
    }
};

pub const Memory = struct {
    entries: [max_stations]Entry = [_]Entry{.{}} ** max_stations,
    count: usize = 0,

    pub fn get(self: *const Memory, base: []const u8) ?*const Entry {
        for (self.entries[0..self.count]) |*e| if (std.mem.eql(u8, e.base(), base)) return e;
        return null;
    }

    pub fn put(self: *Memory, base: []const u8, format: StreamFormat, password: []const u8) !bool {
        if (base.len > max_base_bytes or password.len > 128) return error.OverBound;
        var idx: usize = self.count;
        for (self.entries[0..self.count], 0..) |*e, i| {
            if (std.mem.eql(u8, e.base(), base)) {
                idx = i;
                break;
            }
        }
        if (idx == self.count) {
            if (self.count == max_stations) return error.OverBound;
            self.count += 1;
        }
        const e = &self.entries[idx];
        const changed = !std.mem.eql(u8, e.password(), password);
        @memmove(e.base_store[0..base.len], base);
        e.base_len = base.len;
        @memmove(e.password_store[0..password.len], password);
        if (password.len < e.password_len) @memset(e.password_store[password.len..e.password_len], 0);
        e.password_len = password.len;
        e.format = format;
        return changed;
    }

    pub fn forget(self: *Memory, base: []const u8) bool {
        for (self.entries[0..self.count], 0..) |*e, i| {
            if (!std.mem.eql(u8, e.base(), base)) continue;
            const secret_removed = e.password_len > 0;
            self.count -= 1;
            for (i..self.count) |j| self.entries[j] = self.entries[j + 1];
            @memset(&self.entries[self.count].password_store, 0);
            self.entries[self.count].password_len = 0;
            self.entries[self.count].base_len = 0;
            return secret_removed;
        }
        return false;
    }

    pub fn retain(self: *Memory, current: []const u8, recents: []const []const u8) bool {
        var changed = false;
        var i: usize = 0;
        while (i < self.count) {
            const base = self.entries[i].base();
            var keep = std.mem.eql(u8, base, current);
            for (recents) |recent| keep = keep or std.mem.eql(u8, base, recent);
            if (keep) i += 1 else changed = self.forget(base) or changed;
        }
        return changed;
    }

    pub fn vaultSnapshot(self: *const Memory, buf: []u8) ![]const u8 {
        var w = std.Io.Writer.fixed(buf);
        try w.writeByte('{');
        var first = true;
        for (self.entries[0..self.count]) |*e| {
            if (e.password_len == 0) continue;
            if (!first) try w.writeByte(',');
            first = false;
            var hash_buf: [64]u8 = undefined;
            var encoded: [172]u8 = undefined;
            const password = std.base64.standard.Encoder.encode(&encoded, e.password());
            try w.print("\"{s}\":\"{s}\"", .{ passwordKey(&hash_buf, e.base()), password });
        }
        try w.writeByte('}');
        return w.buffered();
    }

    pub fn mergeVault(self: *Memory, bytes: []const u8, alloc: std.mem.Allocator) !void {
        const parsed = try std.json.parseFromSlice(std.json.ArrayHashMap([]const u8), alloc, bytes, .{});
        defer parsed.deinit();
        // Validate the entire record before changing any imported password.
        var decoded: [max_stations][128]u8 = undefined;
        var lengths: [max_stations]?usize = [_]?usize{null} ** max_stations;
        for (self.entries[0..self.count], 0..) |*e, i| {
            var hash_buf: [64]u8 = undefined;
            const encoded = parsed.value.map.get(passwordKey(&hash_buf, e.base())) orelse continue;
            const len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
            if (len > 128) return error.OverBound;
            try std.base64.standard.Decoder.decode(decoded[i][0..len], encoded);
            if (!std.unicode.utf8ValidateSlice(decoded[i][0..len])) return error.InvalidPassword;
            lengths[i] = len;
        }
        for (self.entries[0..self.count], 0..) |*e, i| {
            if (lengths[i]) |len| {
                @memset(&e.password_store, 0);
                @memcpy(e.password_store[0..len], decoded[i][0..len]);
                e.password_len = len;
            }
        }
        @memset(std.mem.asBytes(&decoded), 0);
    }
};

fn passwordKey(buf: *[64]u8, base: []const u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(base, &digest, .{});
    buf.* = std.fmt.bytesToHex(digest, .lower);
    return buf;
}

pub const Recheck = struct {
    reconnect_since: ?u64 = null,
    last_check: ?u64 = null,

    pub fn due(self: *Recheck, now: u64, reconnecting: bool) bool {
        if (!reconnecting) {
            self.reconnect_since = null;
            return false;
        }
        if (self.reconnect_since == null) self.reconnect_since = now;
        if (now -| self.reconnect_since.? < 15_000) return false;
        if (self.last_check) |last| if (now -| last < 120_000) return false;
        self.last_check = now;
        return true;
    }
};

pub fn diagnostic(buf: []u8, outcome: []const u8, status: u16, tried_https: bool) []const u8 {
    if (std.mem.eql(u8, outcome, "timed_out")) return "No response in time. The box may be asleep, on another network, or blocked by a firewall.";
    if (std.mem.eql(u8, outcome, "ok")) {
        if (status == 401) return "The station asked for a login (HTTP 401). HTTP Basic Station login is not supported by this desktop player. Ask the operator for a station URL without a proxy login.";
        if (status == 407) return "A proxy on this network is asking for a password (HTTP 407). Check this network's proxy settings, or try another network.";
        return std.fmt.bufPrint(buf, "The server answered with HTTP {d}, but not like a SUB/WAVE controller. Check that your reverse proxy routes /api/* to the controller on port 7701.", .{status}) catch "Check that /api/* reaches the controller on port 7701.";
    }
    if (std.mem.eql(u8, outcome, "tls_failed")) {
        const install = switch (builtin.os.tag) {
            .macos => "For a private CA, import its root in Keychain Access and trust it for SSL.",
            .windows => "For a private CA, import its root into Trusted Root Certification Authorities for your user account.",
            else => "For a private CA, install its root in your distribution's system CA trust store and refresh the CA certificates.",
        };
        return std.fmt.bufPrint(buf, "The station's certificate may be invalid or untrusted. Set your reverse proxy to serve the full certificate chain, including intermediates. {s} A publicly trusted certificate or plain http:// on your LAN also work.", .{install}) catch "The station's certificate may be invalid or untrusted. Check its full chain and your system CA trust store.";
    }
    return if (tried_https)
        "Couldn't open a connection. If this address works in your browser, check the station's TLS certificate and full certificate chain. A private CA, DNS, or a firewall on this network can also cause this."
    else
        "Couldn't open a connection. Check the address is right and the station is reachable from this network.";
}

const testing = std.testing;

test "station identity normalizes host, default port and trailing slashes, rejects logins" {
    var b: [256]u8 = undefined;
    try testing.expectEqualStrings("https://radio.example", try normalizeBase(&b, " HTTPS://Radio.Example:443/// "));
    try testing.expectEqualStrings("http://box.local:7701", try normalizeBase(&b, "http://BOX.local:7701/"));
    try testing.expectError(error.StationLoginUnsupported, normalizeBase(&b, "https://user:pass@radio.example"));
    for ([_][]const u8{ "ftp://host", "radio example", "http://", "https://host?secret=x", "https://host/#fragment" }) |bad| {
        try testing.expectError(error.InvalidBase, normalizeBase(&b, bad));
    }
}

test "HTTP consent exempts LAN, private IPv4 and IPv6, never public addresses" {
    for ([_][]const u8{ "localhost", "radio", "BOX.LOCAL", "station.home.arpa", "127.2.3.4", "10.1.2.3", "192.168.1.1", "172.16.0.1", "172.31.255.255", "169.254.1.2", "::1", "fd12::1", "fc00::2", "fe80::1", "::ffff:192.168.1.2" }) |host| try testing.expect(isLocalHost(host));
    for ([_][]const u8{ "radio.example.com", "local.example", "192.169.0.1", "172.15.0.1", "172.32.0.1", "8.8.8.8", "2001:4860::8888", "::ffff:8.8.8.8", "bad::ipv6" }) |host| try testing.expect(!isLocalHost(host));
    try testing.expect(needsHttpConsent("http://radio.example.com"));
    try testing.expect(!needsHttpConsent("https://radio.example.com"));
    try testing.expect(!needsHttpConsent("http://[::1]:7701"));
}

test "memory removal and retention bound it to recents plus current" {
    var m: Memory = .{};
    _ = try m.put("https://one", .opus, "first");
    _ = try m.put("https://two", .flac, "second");
    _ = try m.put("https://three", .aac, "");
    try testing.expect(m.retain("https://two", &.{"https://three"}));
    try testing.expect(m.get("https://one") == null);
    try testing.expectEqual(StreamFormat.flac, m.get("https://two").?.format);
    try testing.expect(m.forget("https://two"));
    try testing.expectEqual(@as(usize, 1), m.count);
    var b: [64]u8 = undefined;
    for (1..max_stations) |i| _ = try m.put(try std.fmt.bufPrint(&b, "https://station{d}", .{i}), .mp3, "");
    try testing.expectError(error.OverBound, m.put("https://overflow", .mp3, ""));
}

test "vault round-trip preserves exact passwords and fits the SDK secret bound" {
    var m: Memory = .{};
    var b: [64]u8 = undefined;
    const secret = [_]u8{'"'} ** 128;
    for (0..max_stations) |i| _ = try m.put(try std.fmt.bufPrint(&b, "https://station{d}", .{i}), .opus, &secret);
    var vault: [vault_bytes]u8 = undefined;
    const bytes = try m.vaultSnapshot(&vault);
    try testing.expect(bytes.len <= 2560);
    for (m.entries[0..m.count]) |*e| e.password_len = 0;
    try m.mergeVault(bytes, testing.allocator);
    for (m.entries[0..m.count]) |*e| try testing.expectEqualStrings(&secret, e.password());
}

test "reconnect checks wait 15 seconds and are limited to once per two minutes" {
    var r: Recheck = .{};
    try testing.expect(!r.due(100, true));
    try testing.expect(!r.due(15_099, true));
    try testing.expect(r.due(15_100, true));
    try testing.expect(!r.due(135_099, true));
    try testing.expect(r.due(135_100, true));
    try testing.expect(!r.due(140_000, false));
    try testing.expect(!r.due(300_000, true));
    try testing.expect(r.due(315_000, true));
}

test "diagnostics distinguish login, proxy, timeout, controller and certificate" {
    var b: [768]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, diagnostic(&b, "ok", 401, true), "not supported") != null);
    try testing.expect(std.mem.indexOf(u8, diagnostic(&b, "ok", 407, true), "proxy settings") != null);
    try testing.expect(std.mem.indexOf(u8, diagnostic(&b, "timed_out", 0, true), "firewall") != null);
    try testing.expect(std.mem.indexOf(u8, diagnostic(&b, "ok", 200, true), "port 7701") != null);
    try testing.expect(std.mem.indexOf(u8, diagnostic(&b, "tls_failed", 0, true), "full certificate chain") != null);
}
