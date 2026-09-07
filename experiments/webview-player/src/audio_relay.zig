//! Bounded, one-load loopback relay for native audio decoders.
//!
//! The decoder sees only `url()`. The configured upstream URL and optional
//! Authorization value stay owned by this object and are sent only by the
//! upstream HTTP client. Redirects are returned as a local 502 and never
//! followed.
const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = Io.net;

pub const Options = struct {
    upstream_url: []const u8,
    authorization: ?[]const u8 = null,
    max_client_header_bytes: usize = 8 * 1024,
    copy_buffer_bytes: usize = 32 * 1024,
};

pub const Relay = struct {
    allocator: Allocator,
    threaded: std.Io.Threaded,
    io: Io,
    listener: net.Server,
    worker: Io.Future(anyerror!void),
    upstream_url: []u8,
    authorization: ?[]u8,
    capability_path: [65]u8,
    local_url: [96]u8,
    local_url_len: usize,
    max_client_header_bytes: usize,
    copy_buffer_bytes: usize,

    /// Allocates and starts a single-use relay. `stop` frees this object.
    pub fn start(allocator: Allocator, options: Options) !*Relay {
        if (options.max_client_header_bytes < 256 or options.max_client_header_bytes > 64 * 1024)
            return error.InvalidHeaderLimit;
        if (options.copy_buffer_bytes < 1024 or options.copy_buffer_bytes > 1024 * 1024)
            return error.InvalidCopyBufferSize;
        try validateUpstream(options.upstream_url);
        if (options.authorization) |value| if (value.len == 0 or value.len > 8 * 1024 or
            std.mem.findAny(u8, value, "\r\n\x00") != null) return error.InvalidAuthorization;

        const self = try allocator.create(Relay);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.upstream_url = try allocator.dupe(u8, options.upstream_url);
        errdefer {
            @memset(self.upstream_url, 0);
            allocator.free(self.upstream_url);
        }
        self.authorization = if (options.authorization) |value| try allocator.dupe(u8, value) else null;
        errdefer if (self.authorization) |value| {
            @memset(value, 0);
            allocator.free(value);
        };
        self.max_client_header_bytes = options.max_client_header_bytes;
        self.copy_buffer_bytes = options.copy_buffer_bytes;
        self.threaded = std.Io.Threaded.init(allocator, .{ .environ = .empty });
        errdefer self.threaded.deinit();
        self.io = self.threaded.io();

        const bind_address = try net.IpAddress.parse("127.0.0.1", 0);
        self.listener = try bind_address.listen(self.io, .{ .reuse_address = false, .kernel_backlog = 1 });
        errdefer self.listener.deinit(self.io);

        var nonce: [32]u8 = undefined;
        try Io.randomSecure(self.io, &nonce);
        self.capability_path[0] = '/';
        _ = std.fmt.bufPrint(self.capability_path[1..], "{x}", .{nonce}) catch unreachable;
        self.local_url_len = (std.fmt.bufPrint(&self.local_url, "http://127.0.0.1:{d}{s}", .{
            self.listener.socket.address.getPort(), self.capability_path[0..],
        }) catch return error.LocalUrlTooLong).len;
        self.worker = try self.io.concurrent(serve, .{self});
        return self;
    }

    pub fn url(self: *const Relay) []const u8 {
        return self.local_url[0..self.local_url_len];
    }

    /// Cancels accept, active downstream I/O and upstream HTTP I/O, waits for
    /// the worker, then destroys all owned state including copied credentials.
    pub fn stop(self: *Relay) void {
        _ = self.worker.cancel(self.io) catch {};
        self.listener.deinit(self.io);
        self.threaded.deinit();
        @memset(self.upstream_url, 0);
        self.allocator.free(self.upstream_url);
        if (self.authorization) |value| {
            @memset(value, 0);
            self.allocator.free(value);
        }
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    fn serve(self: *Relay) anyerror!void {
        // Rejected local requests do not consume the one authorized load. A
        // process that happens to find the ephemeral port still needs the
        // capability path before this relay commits to its upstream request.
        // Cancellation propagates through accept and every later std.Io call.
        while (true) {
            var downstream = try self.listener.accept(self.io);
            defer downstream.close(self.io);
            const admitted = try self.admit(&downstream);
            if (!admitted) continue;
            try self.forward(&downstream);
            return;
        }
    }

    /// Parse and authenticate one downstream request. Complete rejected
    /// requests receive an error response and leave the relay available for
    /// the decoder's later capability-bearing request. A client can still
    /// hold the single accept slot with a partial head; `stop` cancels it.
    fn admit(self: *Relay, downstream: *net.Stream) !bool {
        const head_storage = try self.allocator.alloc(u8, self.max_client_header_bytes);
        defer self.allocator.free(head_storage);
        var socket_read_buffer: [1024]u8 = undefined;
        var reader = downstream.reader(self.io, &socket_read_buffer);
        const head = readHead(&reader.interface, head_storage) catch |err| switch (err) {
            error.HeaderTooLarge => {
                var write_buffer: [512]u8 = undefined;
                var writer = downstream.writer(self.io, &write_buffer);
                try writeError(&writer.interface, 431, "invalid_request");
                return false;
            },
            else => return err,
        };

        const request = parseRequest(head) catch {
            var write_buffer: [512]u8 = undefined;
            var writer = downstream.writer(self.io, &write_buffer);
            try writeError(&writer.interface, 400, "invalid_request");
            return false;
        };
        if (!std.mem.eql(u8, request.method, "GET")) {
            try reject(downstream, self.io, 405, "method_not_allowed");
            return false;
        }
        if (!std.mem.eql(u8, request.target, &self.capability_path)) {
            try reject(downstream, self.io, 404, "not_found");
            return false;
        }
        if (!validDownstreamHeaders(request.headers, self.listener.socket.address.getPort())) {
            try reject(downstream, self.io, 403, "forbidden");
            return false;
        }
        return true;
    }

    fn forward(self: *Relay, downstream: *net.Stream) !void {
        var client: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();
        const uri = try std.Uri.parse(self.upstream_url);
        var auth_headers: [1]std.http.Header = undefined;
        const authorization_headers: []const std.http.Header = if (self.authorization) |value| blk: {
            auth_headers[0] = .{ .name = "Authorization", .value = value };
            break :blk &auth_headers;
        } else &.{};
        var upstream = try client.request(.GET, uri, .{
            .redirect_behavior = .unhandled,
            // Redirects are returned unhandled, so this header can only be
            // serialized on the one configured upstream request.
            .extra_headers = authorization_headers,
            .keep_alive = false,
            .headers = .{ .accept_encoding = .omit },
        });
        defer upstream.deinit();
        try upstream.sendBodiless();
        var response = try upstream.receiveHead(&.{});
        if (response.head.status.class() == .redirect)
            return reject(downstream, self.io, 502, "redirect_denied");
        if (response.head.status != .ok)
            return reject(downstream, self.io, @intFromEnum(response.head.status), "upstream_error");

        var write_storage: [1024]u8 = undefined;
        var writer = downstream.writer(self.io, &write_storage);
        try writer.interface.print("HTTP/1.1 200 OK\r\nConnection: close\r\nCache-Control: no-store\r\n", .{});
        if (response.head.content_type) |value| {
            if (safeHeaderValue(value)) try writer.interface.print("Content-Type: {s}\r\n", .{value});
        }
        if (response.head.content_length) |value| try writer.interface.print("Content-Length: {d}\r\n", .{value});
        try writer.interface.writeAll("\r\n");
        try writer.interface.flush();

        const copy_storage = try self.allocator.alloc(u8, self.copy_buffer_bytes);
        defer self.allocator.free(copy_storage);
        var body = response.reader(copy_storage);
        _ = body.streamRemaining(&writer.interface) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse error.UpstreamReadFailed,
            else => |e| return e,
        };
        try writer.interface.flush();
    }
};

const ParsedRequest = struct { method: []const u8, target: []const u8, headers: []const u8 };

fn validateUpstream(url: []const u8) !void {
    if (url.len == 0 or url.len > 8 * 1024 or std.mem.findAny(u8, url, "\r\n\x00") != null)
        return error.InvalidUpstreamUrl;
    const uri = std.Uri.parse(url) catch return error.InvalidUpstreamUrl;
    if ((!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) or
        uri.host == null or uri.user != null or uri.password != null or uri.fragment != null)
        return error.InvalidUpstreamUrl;
}

fn readHead(reader: *Io.Reader, storage: []u8) ![]const u8 {
    var used: usize = 0;
    while (used < storage.len) {
        storage[used] = try reader.takeByte();
        used += 1;
        if (std.mem.findPosLinear(u8, storage[0..used], 0, "\r\n\r\n")) |end| return storage[0 .. end + 4];
    }
    return error.HeaderTooLarge;
}

fn parseRequest(head: []const u8) !ParsedRequest {
    const line_end = std.mem.findPosLinear(u8, head, 0, "\r\n") orelse return error.InvalidRequest;
    var fields = std.mem.splitScalar(u8, head[0..line_end], ' ');
    const method = fields.next() orelse return error.InvalidRequest;
    const target = fields.next() orelse return error.InvalidRequest;
    const version = fields.next() orelse return error.InvalidRequest;
    if (fields.next() != null or !std.mem.eql(u8, version, "HTTP/1.1") or target.len == 0) return error.InvalidRequest;
    return .{ .method = method, .target = target, .headers = head[line_end + 2 .. head.len - 2] };
}

fn validDownstreamHeaders(headers: []const u8, port: u16) bool {
    var expected_host_buf: [32]u8 = undefined;
    const expected_host = std.fmt.bufPrint(&expected_host_buf, "127.0.0.1:{d}", .{port}) catch return false;
    var saw_host = false;
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.findScalar(u8, line, ':') orelse return false;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (!validHeaderName(name) or std.mem.findAny(u8, value, "\x00") != null) return false;
        if (std.ascii.eqlIgnoreCase(name, "host")) {
            if (saw_host or !std.mem.eql(u8, value, expected_host)) return false;
            saw_host = true;
        }
        if (std.ascii.eqlIgnoreCase(name, "origin") or
            std.ascii.eqlIgnoreCase(name, "authorization") or
            std.ascii.eqlIgnoreCase(name, "proxy-authorization") or
            std.ascii.eqlIgnoreCase(name, "cookie")) return false;
        if (std.ascii.eqlIgnoreCase(name, "content-length") and !std.mem.eql(u8, value, "0")) return false;
        if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) return false;
    }
    return saw_host;
}

fn validHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) != null)) return false;
    return true;
}

fn safeHeaderValue(value: []const u8) bool {
    return std.mem.findAny(u8, value, "\r\n\x00") == null;
}

fn reject(stream: *net.Stream, io: Io, status: u16, code: []const u8) !void {
    var storage: [512]u8 = undefined;
    var writer = stream.writer(io, &storage);
    try writeError(&writer.interface, status, code);
}

fn writeError(writer: *Io.Writer, status: u16, code: []const u8) !void {
    try writer.print("HTTP/1.1 {d} Error\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: {d}\r\n\r\n{s}\n", .{ status, code.len + 1, code });
    try writer.flush();
}

fn stallWithoutResponse(io: Io, listener: *net.Server, request_received: *Io.Event) !void {
    var stream = try listener.accept(io);
    defer stream.close(io);
    var storage: [1024]u8 = undefined;
    var reader = stream.reader(io, &storage);
    while (true) {
        _ = try reader.interface.takeDelimiterInclusive('\n');
        const buffered = reader.interface.buffered();
        if (std.mem.endsWith(u8, buffered, "\r\n\r\n")) break;
        // std.http emits a small request here; the event is merely a precise
        // rendezvous before the server deliberately withholds its response.
        if (reader.interface.seek == 0) break;
    }
    request_received.set(io);
    _ = try reader.interface.takeByte();
}

fn readSyntheticRequest(io: Io, stream: *net.Stream) !void {
    var socket_storage: [1024]u8 = undefined;
    var reader = stream.reader(io, &socket_storage);
    var head_storage: [4096]u8 = undefined;
    _ = try readHead(&reader.interface, &head_storage);
}

fn respondToOneRequest(io: Io, listener: *net.Server, request_received: *Io.Event) !void {
    var stream = try listener.accept(io);
    defer stream.close(io);
    try readSyntheticRequest(io, &stream);
    request_received.set(io);
    var storage: [256]u8 = undefined;
    var writer = stream.writer(io, &storage);
    try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nContent-Length: 1\r\nConnection: close\r\n\r\nx");
    try writer.interface.flush();
}

fn stallResponseBody(io: Io, listener: *net.Server, body_started: *Io.Event) !void {
    var stream = try listener.accept(io);
    defer stream.close(io);
    try readSyntheticRequest(io, &stream);
    var storage: [512]u8 = undefined;
    var writer = stream.writer(io, &storage);
    try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nContent-Length: 1024\r\nConnection: close\r\n\r\nx");
    try writer.interface.flush();
    body_started.set(io);
    var read_storage: [1]u8 = undefined;
    var reader = stream.reader(io, &read_storage);
    _ = try reader.interface.takeByte();
}

fn floodResponseBody(io: Io, listener: *net.Server, body_started: *Io.Event) !void {
    var stream = try listener.accept(io);
    defer stream.close(io);
    try readSyntheticRequest(io, &stream);
    var storage: [32 * 1024]u8 = undefined;
    var writer = stream.writer(io, &storage);
    try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nConnection: close\r\n\r\n");
    try writer.interface.flush();
    body_started.set(io);
    const chunk = [_]u8{0x55} ** (32 * 1024);
    while (true) {
        try writer.interface.writeAll(&chunk);
        try writer.interface.flush();
    }
}

test "upstream rejects userinfo and non-HTTP schemes" {
    try std.testing.expectError(error.InvalidUpstreamUrl, validateUpstream("http://u:p@127.0.0.1:9/stream.mp3"));
    try std.testing.expectError(error.InvalidUpstreamUrl, validateUpstream("file:///tmp/tone.mp3"));
    try validateUpstream("http://127.0.0.1:43127/stream.mp3");
}

test "upstream and authorization reject request splitting bytes" {
    try std.testing.expectError(error.InvalidUpstreamUrl, validateUpstream("http://127.0.0.1:9/a\rb"));
    try std.testing.expectError(error.InvalidUpstreamUrl, validateUpstream("http://127.0.0.1:9/a\nb"));
    try std.testing.expectError(error.InvalidUpstreamUrl, validateUpstream("http://127.0.0.1:9/a\x00b"));
    try std.testing.expectError(error.InvalidAuthorization, Relay.start(std.testing.allocator, .{
        .upstream_url = "http://127.0.0.1:9/stream.mp3",
        .authorization = "Basic sentinel\rvalue",
    }));
}

test "downstream requires exact Host and rejects browser and credential headers" {
    try std.testing.expect(validDownstreamHeaders("Host: 127.0.0.1:43127\r\n", 43127));
    try std.testing.expect(!validDownstreamHeaders("Host: localhost:43127\r\n", 43127));
    try std.testing.expect(!validDownstreamHeaders("Host: 127.0.0.1:43127\r\nOrigin: null\r\n", 43127));
    try std.testing.expect(!validDownstreamHeaders("Host: 127.0.0.1:43127\r\nAuthorization: Basic sentinel\r\n", 43127));
    try std.testing.expect(!validDownstreamHeaders("Host: 127.0.0.1:43127\r\nBad Name: value\r\n", 43127));
}

test "start binds an ephemeral literal loopback capability and stop joins worker" {
    const relay = try Relay.start(std.testing.allocator, .{
        .upstream_url = "http://127.0.0.1:9/stream.mp3",
    });
    try std.testing.expect(std.mem.startsWith(u8, relay.url(), "http://127.0.0.1:"));
    try std.testing.expect(std.mem.endsWith(u8, relay.url(), &relay.capability_path));
    try std.testing.expectEqual(@as(usize, 65), relay.capability_path.len);
    relay.stop();
}

test "stop cancels a client stalled in a partial request head" {
    const relay = try Relay.start(std.testing.allocator, .{
        .upstream_url = "http://127.0.0.1:9/stream.mp3",
    });
    var client_io_threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = .empty });
    defer client_io_threaded.deinit();
    const client_io = client_io_threaded.io();
    const address = try net.IpAddress.parse("127.0.0.1", relay.listener.socket.address.getPort());
    var client = try address.connect(client_io, .{ .mode = .stream, .protocol = .tcp });
    defer client.close(client_io);
    var storage: [128]u8 = undefined;
    var writer = client.writer(client_io, &storage);
    try writer.interface.writeAll("GET /partial HTTP/1.1\r\nHost:");
    try writer.interface.flush();
    relay.stop();
}

test "a malformed complete request does not consume the capability load" {
    var upstream_threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = .empty });
    defer upstream_threaded.deinit();
    const upstream_io = upstream_threaded.io();
    const bind_address = try net.IpAddress.parse("127.0.0.1", 0);
    var upstream_listener = try bind_address.listen(upstream_io, .{ .reuse_address = false, .kernel_backlog = 1 });
    defer upstream_listener.deinit(upstream_io);
    var request_received: Io.Event = .unset;
    var upstream_worker = try upstream_io.concurrent(respondToOneRequest, .{ upstream_io, &upstream_listener, &request_received });
    defer _ = upstream_worker.cancel(upstream_io) catch {};
    var upstream_url_storage: [128]u8 = undefined;
    const upstream_url = try std.fmt.bufPrint(&upstream_url_storage, "http://127.0.0.1:{d}/stream.mp3", .{upstream_listener.socket.address.getPort()});
    const relay = try Relay.start(std.testing.allocator, .{
        .upstream_url = upstream_url,
    });
    var client_io_threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = .empty });
    defer client_io_threaded.deinit();
    const client_io = client_io_threaded.io();
    const address = try net.IpAddress.parse("127.0.0.1", relay.listener.socket.address.getPort());

    {
        var rejected = try address.connect(client_io, .{ .mode = .stream, .protocol = .tcp });
        defer rejected.close(client_io);
        var write_storage: [256]u8 = undefined;
        var writer = rejected.writer(client_io, &write_storage);
        try writer.interface.print("GET /wrong HTTP/1.0\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n", .{relay.listener.socket.address.getPort()});
        try writer.interface.flush();
        var read_storage: [256]u8 = undefined;
        var reader = rejected.reader(client_io, &read_storage);
        const response = try reader.interface.allocRemaining(std.testing.allocator, .limited(1024));
        defer std.testing.allocator.free(response);
        try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 400"));
    }

    {
        var admitted = try address.connect(client_io, .{ .mode = .stream, .protocol = .tcp });
        defer admitted.close(client_io);
        var storage: [512]u8 = undefined;
        var writer = admitted.writer(client_io, &storage);
        try writer.interface.print("GET {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n", .{
            &relay.capability_path, relay.listener.socket.address.getPort(),
        });
        try writer.interface.flush();
        var read_storage: [512]u8 = undefined;
        var reader = admitted.reader(client_io, &read_storage);
        const response = try reader.interface.allocRemaining(std.testing.allocator, .limited(1024));
        defer std.testing.allocator.free(response);
        try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK"));
        try std.testing.expect(std.mem.endsWith(u8, response, "\r\n\r\nx"));
    }
    try request_received.waitTimeout(client_io, .{ .duration = .{ .clock = .boot, .raw = .fromSeconds(2) } });
    relay.stop();
}

test "stop joins a relay waiting for upstream response headers" {
    var upstream_threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = .empty });
    defer upstream_threaded.deinit();
    const upstream_io = upstream_threaded.io();
    const bind_address = try net.IpAddress.parse("127.0.0.1", 0);
    var upstream_listener = try bind_address.listen(upstream_io, .{ .reuse_address = false, .kernel_backlog = 1 });
    defer upstream_listener.deinit(upstream_io);
    var request_received: Io.Event = .unset;
    var upstream_worker = try upstream_io.concurrent(stallWithoutResponse, .{ upstream_io, &upstream_listener, &request_received });
    defer _ = upstream_worker.cancel(upstream_io) catch {};

    var upstream_url_storage: [128]u8 = undefined;
    const upstream_url = try std.fmt.bufPrint(&upstream_url_storage, "http://127.0.0.1:{d}/stream.mp3", .{upstream_listener.socket.address.getPort()});
    const relay = try Relay.start(std.testing.allocator, .{ .upstream_url = upstream_url });
    var client_io_threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = .empty });
    defer client_io_threaded.deinit();
    const client_io = client_io_threaded.io();
    const relay_address = try net.IpAddress.parse("127.0.0.1", relay.listener.socket.address.getPort());
    var client = try relay_address.connect(client_io, .{ .mode = .stream, .protocol = .tcp });
    defer client.close(client_io);
    var write_storage: [512]u8 = undefined;
    var writer = client.writer(client_io, &write_storage);
    try writer.interface.print("GET {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n", .{
        &relay.capability_path, relay.listener.socket.address.getPort(),
    });
    try writer.interface.flush();
    try request_received.waitTimeout(client_io, .{ .duration = .{ .clock = .boot, .raw = .fromSeconds(2) } });
    relay.stop();
}

test "stop joins a relay waiting for the rest of an upstream body" {
    var upstream_threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = .empty });
    defer upstream_threaded.deinit();
    const upstream_io = upstream_threaded.io();
    const bind_address = try net.IpAddress.parse("127.0.0.1", 0);
    var upstream_listener = try bind_address.listen(upstream_io, .{ .reuse_address = false, .kernel_backlog = 1 });
    defer upstream_listener.deinit(upstream_io);
    var body_started: Io.Event = .unset;
    var upstream_worker = try upstream_io.concurrent(stallResponseBody, .{ upstream_io, &upstream_listener, &body_started });
    defer _ = upstream_worker.cancel(upstream_io) catch {};

    var upstream_url_storage: [128]u8 = undefined;
    const upstream_url = try std.fmt.bufPrint(&upstream_url_storage, "http://127.0.0.1:{d}/stream.mp3", .{upstream_listener.socket.address.getPort()});
    const relay = try Relay.start(std.testing.allocator, .{ .upstream_url = upstream_url });
    var client_io_threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = .empty });
    defer client_io_threaded.deinit();
    const client_io = client_io_threaded.io();
    const relay_address = try net.IpAddress.parse("127.0.0.1", relay.listener.socket.address.getPort());
    var client = try relay_address.connect(client_io, .{ .mode = .stream, .protocol = .tcp });
    defer client.close(client_io);
    var storage: [512]u8 = undefined;
    var writer = client.writer(client_io, &storage);
    try writer.interface.print("GET {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n", .{ &relay.capability_path, relay.listener.socket.address.getPort() });
    try writer.interface.flush();
    try body_started.waitTimeout(client_io, .{ .duration = .{ .clock = .boot, .raw = .fromSeconds(2) } });
    relay.stop();
}

test "stop joins a relay under downstream backpressure" {
    var upstream_threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = .empty });
    defer upstream_threaded.deinit();
    const upstream_io = upstream_threaded.io();
    const bind_address = try net.IpAddress.parse("127.0.0.1", 0);
    var upstream_listener = try bind_address.listen(upstream_io, .{ .reuse_address = false, .kernel_backlog = 1 });
    defer upstream_listener.deinit(upstream_io);
    var body_started: Io.Event = .unset;
    var upstream_worker = try upstream_io.concurrent(floodResponseBody, .{ upstream_io, &upstream_listener, &body_started });
    defer _ = upstream_worker.cancel(upstream_io) catch {};

    var upstream_url_storage: [128]u8 = undefined;
    const upstream_url = try std.fmt.bufPrint(&upstream_url_storage, "http://127.0.0.1:{d}/stream.mp3", .{upstream_listener.socket.address.getPort()});
    const relay = try Relay.start(std.testing.allocator, .{ .upstream_url = upstream_url, .copy_buffer_bytes = 1024 });
    var client_io_threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = .empty });
    defer client_io_threaded.deinit();
    const client_io = client_io_threaded.io();
    const relay_address = try net.IpAddress.parse("127.0.0.1", relay.listener.socket.address.getPort());
    var client = try relay_address.connect(client_io, .{ .mode = .stream, .protocol = .tcp });
    defer client.close(client_io);
    var storage: [512]u8 = undefined;
    var writer = client.writer(client_io, &storage);
    try writer.interface.print("GET {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n", .{ &relay.capability_path, relay.listener.socket.address.getPort() });
    try writer.interface.flush();
    try body_started.waitTimeout(client_io, .{ .duration = .{ .clock = .boot, .raw = .fromSeconds(2) } });
    try Io.Clock.Duration.sleep(.{ .clock = .boot, .raw = .fromMilliseconds(100) }, client_io);
    relay.stop();
}
