//! One bounded asynchronous HTTP owner for the WebView host.
const std = @import("std");
const sdk = @import("native_sdk");
const client = @import("station_client.zig");
const identity = @import("station_identity.zig");
const decoders = @import("station_decoders.zig");

pub const RequestTag = struct {
    operation_id: u64,
    generation: u64,
    request_id: u64,
    kind: client.Endpoint,
};
pub const Failure = enum {
    rejected,
    cancelled,
    timed_out,
    connect_failed,
    tls_failed,
    protocol_failed,
    redirect_denied,
    auth_required,
    forbidden,
    rate_limited,
    http_error,
    response_too_large,
    invalid_response,
    delivery_lost,
};
pub const Completion = struct {
    tag: RequestTag,
    status: u16,
    result: union(enum) { data: decoders.Decoded, failure: Failure },

    pub fn deinit(self: *Completion) void {
        if (self.result == .data) self.result.data.deinit();
        self.* = undefined;
    }
};
const Msg = union(enum) { response: sdk.EffectResponse };
const Fx = sdk.Effects(Msg);
const Slot = struct { tag: RequestTag, cancelled: bool = false };
pub const max_requests = 8;

pub const Owner = struct {
    allocator: std.mem.Allocator,
    effects: *Fx,
    slots: [max_requests]?Slot = .{null} ** max_requests,
    next_key: u64 = 1_000_000,
    stopped: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Owner {
        const effects = try allocator.create(Fx);
        effects.* = Fx.init(allocator);
        return .{ .allocator = allocator, .effects = effects };
    }

    /// Bind before any submission. The runtime remains alive until stop().
    pub fn bind(self: *Owner, runtime: *sdk.Runtime) void {
        self.effects.bindServices(&runtime.options.platform.services);
        self.effects.bindEnviron(runtime.options.environ);
        self.effects.bindCredentialsStore(.{
            .services = &runtime.options.platform.services,
            .service = runtime.options.platform.app_info.bundle_id,
            .permitted = runtime.options.credentials_enabled and
                sdk.security.hasPermission(runtime.options.security.permissions, sdk.security.permission_credentials),
        });
        if (runtime.options.file_access) |binding| {
            self.effects.bindFileAccess(binding);
        } else self.effects.bindFileAccess(.{ .roots = &.{}, .permitted = false, .enforce = true });
    }

    /// Run from the App stop hook before platform teardown. Effects.deinit is
    /// idempotent; deinit() may safely follow after the runner returns.
    pub fn stop(self: *Owner) void {
        self.stopped = true;
        self.effects.deinit();
        self.slots = .{null} ** max_requests;
    }

    pub fn deinit(self: *Owner) void {
        self.stop();
        self.allocator.destroy(self.effects);
        self.* = undefined;
    }

    pub fn request(self: *Owner, station: *const identity.StationIdentity, operation_id: u64, generation: u64, kind: client.Endpoint, auth: client.Auth, body: ?[]const u8) !RequestTag {
        if (self.stopped) return error.Stopped;
        if ((kind == .station_auth) != (body != null)) return error.InvalidRequest;
        // A listener password in POST JSON needs the same HTTP consent as a header.
        if (body != null and std.mem.startsWith(u8, station.base(), "http://") and !auth.allow_insecure_http)
            return error.InsecureCredentials;
        if (body) |value| if (value.len > 8192) return error.InvalidRequest;
        var free: ?usize = null;
        for (self.slots, 0..) |maybe, index| {
            if (maybe) |slot| {
                if (slot.tag.operation_id == operation_id and slot.tag.generation == generation and slot.tag.kind == kind)
                    return error.Busy;
            } else if (free == null) free = index;
        }
        const index = free orelse return error.Busy;
        if (self.next_key == std.math.maxInt(u64)) return error.IdentityExhausted;
        var url_store: [512]u8 = undefined;
        var auth_header_store: [2]std.http.Header = undefined;
        var header_store: [3]std.http.Header = undefined;
        const target = try client.url(station, kind, &url_store);
        const auth_headers = try client.headers(station, auth, &auth_header_store);
        @memcpy(header_store[0..auth_headers.len], auth_headers);
        var header_count = auth_headers.len;
        if (body != null) {
            header_store[header_count] = .{ .name = "Content-Type", .value = "application/json" };
            header_count += 1;
        }
        const hs = header_store[0..header_count];
        var header_bytes: usize = 0;
        for (hs) |header| header_bytes += header.name.len + header.value.len;
        if (header_bytes > sdk.max_effect_fetch_header_bytes) return error.CredentialTransportTooLarge;
        const tag: RequestTag = .{ .operation_id = operation_id, .generation = generation, .request_id = self.next_key, .kind = kind };
        self.next_key += 1;
        self.slots[index] = .{ .tag = tag };
        self.effects.fetch(.{
            .key = tag.request_id,
            .method = if (kind == .station_auth) .POST else .GET,
            .url = target,
            .headers = hs,
            .body = body,
            .timeout_ms = 8_000,
            .follow_redirects = false,
            .on_response = onResponse,
        });
        return tag;
    }

    fn onResponse(response: sdk.EffectResponse) Msg {
        return .{ .response = response };
    }

    pub fn cancelOperation(self: *Owner, operation_id: u64) void {
        for (&self.slots) |*maybe| if (maybe.*) |*slot| {
            if (slot.tag.operation_id == operation_id and !slot.cancelled) {
                slot.cancelled = true;
                self.effects.cancel(slot.tag.request_id);
            }
        };
    }

    pub fn cancelGeneration(self: *Owner, generation: u64) void {
        for (&self.slots) |*maybe| if (maybe.*) |*slot| {
            if (slot.tag.generation == generation and !slot.cancelled) {
                slot.cancelled = true;
                self.effects.cancel(slot.tag.request_id);
            }
        };
    }

    pub fn boundary(self: *Owner) Fx.DrainBoundary {
        return self.effects.drainBoundary();
    }

    /// Decode/copy before takeMsgWithin can reclaim its borrowed body. The
    /// consumer owns the returned completion and must deinit it.
    pub fn next(self: *Owner, boundary_value: *Fx.DrainBoundary) ?Completion {
        while (self.effects.takeMsgWithin(boundary_value)) |msg| {
            const response = msg.response;
            var matched: ?Slot = null;
            for (&self.slots) |*maybe| if (maybe.*) |slot| {
                if (slot.tag.request_id == response.key) {
                    matched = slot;
                    maybe.* = null;
                    break;
                }
            };
            const slot = matched orelse continue;
            if (slot.cancelled) continue;
            const result: Completion = .{ .tag = slot.tag, .status = response.status, .result = .{
                .failure = classify(response) orelse blk: {
                    const decoded = decoders.decode(self.allocator, slot.tag.kind, response.body) catch
                        break :blk Failure.invalid_response;
                    return .{ .tag = slot.tag, .status = response.status, .result = .{ .data = decoded } };
                },
            } };
            return result;
        }
        return null;
    }
};

fn classify(response: sdk.EffectResponse) ?Failure {
    if (response.dropped_before != 0) return .delivery_lost;
    if (response.truncated or response.body.len > decoders.max_body_bytes) return .response_too_large;
    if (response.outcome != .ok) return switch (response.outcome) {
        .ok => unreachable,
        .rejected => .rejected,
        .cancelled => .cancelled,
        .timed_out => .timed_out,
        .connect_failed => .connect_failed,
        .tls_failed => .tls_failed,
        .protocol_failed => .protocol_failed,
    };
    if (response.status >= 300 and response.status < 400) return .redirect_denied;
    return switch (response.status) {
        200...299 => null,
        401 => .auth_required,
        403 => .forbidden,
        429 => .rate_limited,
        else => .http_error,
    };
}

test "requests are bounded and canceled responses cannot alias a replacement" {
    var owner = try Owner.init(std.testing.allocator);
    defer owner.deinit();
    owner.effects.executor = .fake;
    var station: identity.StationIdentity = .{};
    _ = try identity.normalizeStation("https://radio.example", &station);
    const first = try owner.request(&station, 1, 1, .health, .{}, null);
    try std.testing.expectError(error.Busy, owner.request(&station, 1, 1, .health, .{}, null));
    const recorded = owner.effects.pendingFetchAt(0).?;
    try std.testing.expect(!recorded.follow_redirects);
    try owner.effects.feedResponse(first.request_id, 200, "{\"status\":\"on-air\"}");
    owner.cancelOperation(1);
    const second = try owner.request(&station, 2, 2, .health, .{}, null);
    try std.testing.expect(second.request_id > first.request_id);
    try owner.effects.feedResponse(second.request_id, 200, "{\"status\":\"on-air\"}");
    var boundary_value = owner.boundary();
    var response = owner.next(&boundary_value).?;
    defer response.deinit();
    try std.testing.expectEqual(@as(u64, 2), response.tag.operation_id);
    try std.testing.expectEqual(true, response.result.data.payload.health.isHealthy());
    try std.testing.expect(owner.next(&boundary_value) == null);
}

test "HTTP failure categories and borrowed response data remain separate" {
    var owner = try Owner.init(std.testing.allocator);
    defer owner.deinit();
    owner.effects.executor = .fake;
    var station: identity.StationIdentity = .{};
    _ = try identity.normalizeStation("https://radio.example", &station);
    const first = try owner.request(&station, 1, 1, .now_playing, .{}, null);
    const second = try owner.request(&station, 1, 1, .state, .{}, null);
    try owner.effects.feedResponse(first.request_id, 200, "{\"nowPlaying\":{\"title\":\"Owned Track\"}}");
    try owner.effects.feedResponse(second.request_id, 307, "secret body must not escape");
    var boundary_value = owner.boundary();
    var track = owner.next(&boundary_value).?;
    defer track.deinit();
    var redirect = owner.next(&boundary_value).?;
    defer redirect.deinit();
    try std.testing.expectEqualStrings("Owned Track", track.result.data.payload.now_playing.track.?.title.?);
    try std.testing.expectEqual(Failure.redirect_denied, redirect.result.failure);
    try std.testing.expectEqual(Failure.timed_out, classify(.{ .key = 1, .outcome = .timed_out }).?);
    try std.testing.expectEqual(Failure.response_too_large, classify(.{ .key = 1, .status = 200, .truncated = true }).?);
}

test "unsupported credential size is rejected before reserving a request" {
    var owner = try Owner.init(std.testing.allocator);
    defer owner.deinit();
    owner.effects.executor = .fake;
    var station: identity.StationIdentity = .{};
    _ = try identity.normalizeStation("https://radio.example", &station);
    try std.testing.expectError(error.CredentialTransportTooLarge, owner.request(&station, 1, 1, .health, .{ .authorization = "Basic " ++ ("x" ** sdk.max_effect_fetch_header_bytes) }, null));
    try std.testing.expectEqual(@as(usize, 0), owner.effects.pendingFetchCount());
    for (owner.slots) |slot| try std.testing.expect(slot == null);
    owner.stop();
    try std.testing.expectError(error.Stopped, owner.request(&station, 1, 1, .health, .{}, null));
}

test "request capacity is retained through cancellation and recovered on drain" {
    var owner = try Owner.init(std.testing.allocator);
    defer owner.deinit();
    owner.effects.executor = .fake;
    var station: identity.StationIdentity = .{};
    _ = try identity.normalizeStation("https://radio.example", &station);
    for (0..max_requests) |index| _ = try owner.request(&station, index + 1, 1, .health, .{}, null);
    try std.testing.expectError(error.Busy, owner.request(&station, 99, 2, .health, .{}, null));
    owner.cancelGeneration(1);
    try std.testing.expectError(error.Busy, owner.request(&station, 99, 2, .health, .{}, null));
    var boundary_value = owner.boundary();
    try std.testing.expect(owner.next(&boundary_value) == null);
    const next_request = try owner.request(&station, 99, 2, .health, .{}, null);
    try owner.effects.feedResponse(next_request.request_id, 200, "malformed JSON");
    boundary_value = owner.boundary();
    var failure = owner.next(&boundary_value).?;
    defer failure.deinit();
    try std.testing.expectEqual(Failure.invalid_response, failure.result.failure);
}

test "listener validation is a consented JSON POST with no listener header" {
    var owner = try Owner.init(std.testing.allocator);
    defer owner.deinit();
    owner.effects.executor = .fake;
    var station: identity.StationIdentity = .{};
    _ = try identity.normalizeStation("http://127.0.0.1:43127", &station);
    const body = "{\"password\":\"listener-sentinel\"}";
    try std.testing.expectError(error.InsecureCredentials, owner.request(&station, 1, 1, .station_auth, .{}, body));
    _ = try owner.request(&station, 1, 1, .station_auth, .{ .allow_insecure_http = true }, body);
    const pending = owner.effects.pendingFetchAt(0).?;
    try std.testing.expectEqual(std.http.Method.POST, pending.method);
    try std.testing.expectEqualStrings(body, pending.body);
    try std.testing.expectEqual(@as(usize, 1), pending.headers.len);
    try std.testing.expectEqualStrings("Content-Type", pending.headers[0].name);
    try std.testing.expectEqualStrings("application/json", pending.headers[0].value);
    try std.testing.expect(!pending.follow_redirects);
}
