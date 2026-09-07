//! Application coordinator for the native station foundation.
const std = @import("std");
const sdk = @import("native_sdk");
const protocol = @import("station_protocol.zig");
const session_host = @import("session_host.zig");
const candidate_connection = @import("candidate_connection.zig");
const selection = @import("station_selection.zig");
const preferences = @import("preferences.zig");
const persistence = @import("persistence_worker.zig");
const store = @import("preferences_store.zig");
const forget_transaction = @import("forget_transaction.zig");
const import_transaction = @import("import_transaction.zig");
const station_identity = @import("station_identity.zig");

pub const Model = struct {
    allocator: std.mem.Allocator,
    host: session_host.Host,
    worker: *persistence.Worker,
    prefs: preferences.Decoded,
    desired_prefs: ?preferences.Decoded = null,
    save_snapshot: ?preferences.Decoded = null,
    candidate: ?candidate_connection.Transaction = null,
    candidate_preferences: ?preferences.Decoded = null,
    candidate_format: protocol.StreamFormat = .mp3,
    forget: ?forget_transaction.Transaction = null,
    forget_file_request: ?u64 = null,
    forget_reconcile_startup: bool = false,
    forget_marker_committed: bool = false,
    forget_station_id: [protocol.max_station_id_bytes]u8 = undefined,
    forget_station_id_len: u8 = 0,
    forget_marked_preferences: ?preferences.Decoded = null,
    forget_vault_request: ?struct { effect: @import("host_effects.zig").VaultTag, request_id: u64 } = null,
    import: ?import_transaction.Transaction = null,
    import_vault_request: ?struct { effect: @import("host_effects.zig").VaultTag, request_id: u64, operation: import_transaction.VaultOperation } = null,
    candidate_persists: bool = true,
    pending_resolution: ?selection.Resolution = null,
    save_policy: store.SavePolicy = .{},
    prefs_revision: u64 = 0,
    cold_load_id: ?u64 = null,
    save_id: ?u64 = null,
    save_revision: ?u64 = null,
    latest_persistence: ?protocol.OperationStatus = null,
    operation_queue: [8]?protocol.OperationResult = @splat(null),
    operation_head: usize = 0,
    operation_count: usize = 0,
    pending_preference_operations: [8]struct { id: u64 = 0, revision: u64 = 0 } = @splat(.{}),
    pending_preference_count: usize = 0,
    recents: [preferences.max_stations]protocol.Station = undefined,
    override_storage: [1024]u8 = undefined,
    override_len: usize = 0,
    started: bool = false,
    worker_alive: bool = true,

    pub fn init(allocator: std.mem.Allocator, env_map: *std.process.Environ.Map) !Model {
        var new_path: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var legacy_path: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const env = sdk.debug.envFromMap(env_map);
        const platform = sdk.app_dirs.currentPlatform();
        const new_dir = try sdk.app_dirs.resolveOne(.{ .name = "subwave-player-next" }, platform, env, .config, &new_path);
        const legacy_dir = try sdk.app_dirs.resolveOne(.{ .name = "subwave-player" }, platform, env, .config, &legacy_path);
        var host = try session_host.Host.init(allocator);
        errdefer host.deinit();
        const worker = try persistence.Worker.init(allocator, new_dir, legacy_dir);
        errdefer worker.stop();
        var prefs = try preferences.decode(allocator, "{\"version\":2}");
        errdefer prefs.deinit();
        var result: Model = .{ .allocator = allocator, .host = host, .worker = worker, .prefs = prefs };
        if (env_map.get("SUBWAVE_STATION_URL")) |value| {
            if (value.len > result.override_storage.len) return error.InvalidStationOverride;
            @memcpy(result.override_storage[0..value.len], value);
            result.override_len = value.len;
        }
        return result;
    }

    pub fn start(self: *Model, runtime: *sdk.Runtime, now_ms: u64) !void {
        _ = now_ms;
        if (self.started) return error.AlreadyStarted;
        try self.host.bind(runtime);
        self.started = true;
        const id = try self.operationId();
        self.cold_load_id = id;
        self.latest_persistence = pending(id);
        self.host.revision += 1;
        self.worker.submit(id, .load, "") catch |err| {
            self.cold_load_id = null;
            self.latest_persistence = failed(id, @errorName(err));
            self.host.revision += 1;
            return err;
        };
    }

    pub fn command(self: *Model, services: sdk.platform.PlatformServices, command_value: protocol.Command, now_ms: u64) !protocol.Accepted {
        return switch (command_value) {
            .snapshot => .{ .ok = true },
            .stationConnect => |connect| self.beginCandidate(connect, true),
            .stationCancel => |id| self.cancelCandidate(id),
            .stationDisconnect => blk: {
                if (self.mutationBlocked()) break :blk rejected(.busy);
                const id = try self.operationId();
                self.host.disconnect(services, now_ms) catch |err| {
                    self.emit(id, false, @errorName(err));
                    break :blk .{ .ok = true, .operationId = id };
                };
                const desired = try self.ensureDesired();
                desired.value.activeStationId = null;
                self.markDirty(now_ms);
                self.emit(id, true, null);
                break :blk .{ .ok = true, .operationId = id };
            },
            .playbackCommand => |playback| blk: {
                switch (playback) {
                    .volume, .format => if (self.mutationBlocked()) break :blk rejected(.busy),
                    else => {},
                }
                const id = try self.operationId();
                self.host.command(services, playback, now_ms) catch |err| {
                    self.emit(id, false, @errorName(err));
                    break :blk .{ .ok = true, .operationId = id };
                };
                switch (playback) {
                    .volume => |volume| {
                        const desired = try self.ensureDesired();
                        desired.value.volume = volume;
                        self.markDirty(now_ms);
                    },
                    .format => |format| {
                        const desired = try self.ensureDesired();
                        try setStationFormat(desired, self.host.selection.active_station, format);
                        self.markDirty(now_ms);
                        self.host.format_dirty = false;
                    },
                    else => {},
                }
                self.emit(id, true, null);
                break :blk .{ .ok = true, .operationId = id };
            },
            .preferencesUpdate => |update| self.updatePreference(update, now_ms),
            // These commands require their compensating transaction. Refuse
            // them until that transaction is attached rather than performing
            // a partial, non-durable mutation.
            .stationForget => |station_id| self.beginForget(station_id),
            .preferencesImportLegacy => self.beginImport(),
        };
    }

    pub fn drain(self: *Model, services: sdk.platform.PlatformServices, now_ms: u64) !void {
        try self.host.drainIntercept(services, now_ms, if (self.candidate != null) .{ .context = self, .consume = consumeCandidate } else null);
        try self.consumeFormatDirty(now_ms);
        while (self.host.http.nextVault()) |raw| {
            var completion = raw;
            defer completion.deinit();
            if (self.candidate) |*transaction| if (transaction.ownsVault(completion.tag)) {
                if (try transaction.onVault(&completion)) |resolution| try self.resolveCandidate(services, resolution, now_ms);
                continue;
            };
            if (self.forget_vault_request) |pending_vault| if (std.meta.eql(pending_vault.effect, completion.tag)) {
                self.forget_vault_request = null;
                const outcome: forget_transaction.Outcome = switch (completion.outcome) {
                    .ok => .ok,
                    .miss => .miss,
                    .locked => .locked,
                    .denied => .denied,
                    .io_failed => .io_failed,
                    .over_bound, .rejected => .rejected,
                };
                try self.driveForget(self.forget.?.onVault(.{ .operation_id = completion.tag.operation_id, .request_id = pending_vault.request_id, .outcome = if (completion.cancelled) .cancelled else outcome }), now_ms);
                continue;
            };
            if (self.import_vault_request) |pending_vault| if (std.meta.eql(pending_vault.effect, completion.tag)) {
                self.import_vault_request = null;
                try self.driveImport(self.import.?.onVault(.{ .operation_id = completion.tag.operation_id, .request_id = pending_vault.request_id, .operation = pending_vault.operation, .outcome = completion.outcome, .bytes = completion.bytes() }), now_ms);
            };
        }
        if (self.pending_resolution) |resolution| {
            self.pending_resolution = null;
            try self.resolveCandidate(services, resolution, now_ms);
        }
        if (self.worker.poll()) |raw| {
            var result = raw;
            defer result.deinit();
            try self.onWorker(result, services, now_ms);
        }
        try self.maybeSave(now_ms);
    }

    pub fn onAudio(self: *Model, services: sdk.platform.PlatformServices, event: sdk.platform.AudioEvent, now_ms: u64) !void {
        try self.host.onAudio(services, event, now_ms);
        try self.consumeFormatDirty(now_ms);
    }
    pub fn onTimer(self: *Model, services: sdk.platform.PlatformServices, id: u64, now_ms: u64) !void {
        try self.host.onTimer(services, id, now_ms);
        try self.consumeFormatDirty(now_ms);
    }

    pub fn snapshot(self: *Model, now_ms: u64) protocol.StationSnapshot {
        var result = self.host.snapshot(now_ms);
        for (self.prefs.value.stations, 0..) |station, i| self.recents[i] = .{ .id = station.id, .base = station.base, .name = station.name };
        if (result.station) |*active| for (self.prefs.value.stations) |station| if (std.mem.eql(u8, station.id, active.id)) {
            active.name = station.name;
            break;
        };
        result.recents = self.recents[0..self.prefs.value.stations.len];
        result.preferences = .{ .themeOverride = self.prefs.value.themeOverride, .discordEnabled = self.prefs.value.discordEnabled, .discordClientId = self.prefs.value.discordClientId, .notifyTrack = self.prefs.value.notifyTrack };
        result.operations.persistence = self.latest_persistence;
        return result;
    }

    pub fn nextOperation(self: *Model) ?protocol.OperationResult {
        if (self.operation_count == 0) return null;
        const value = self.operation_queue[self.operation_head].?;
        self.operation_queue[self.operation_head] = null;
        self.operation_head = (self.operation_head + 1) % self.operation_queue.len;
        self.operation_count -= 1;
        return value;
    }

    pub fn stop(self: *Model, services: sdk.platform.PlatformServices) void {
        if (!self.worker_alive) return;
        if (self.candidate) |*transaction| {
            _ = transaction.cancel() catch null;
            transaction.deinit();
            self.candidate = null;
        }
        if (self.candidate_preferences) |*value| value.deinit();
        self.candidate_preferences = null;
        if (self.started) self.host.stop(services);
        self.worker.stop();
        self.worker_alive = false;
        self.started = false;
    }
    pub fn deinit(self: *Model) void {
        std.debug.assert(!self.started);
        if (self.worker_alive) self.worker.stop();
        if (self.candidate) |*transaction| transaction.deinit();
        if (self.candidate_preferences) |*value| value.deinit();
        if (self.forget) |*transaction| transaction.deinit();
        if (self.forget_marked_preferences) |*value| value.deinit();
        if (self.import) |*transaction| transaction.deinit();
        if (self.desired_prefs) |*value| value.deinit();
        if (self.save_snapshot) |*value| value.deinit();
        self.prefs.deinit();
        self.host.deinit();
        std.crypto.secureZero(u8, &self.override_storage);
    }

    fn beginCandidate(self: *Model, connect: protocol.Connect, persist: bool) !protocol.Accepted {
        if (self.mutationBlocked()) return rejected(.busy);
        if (persist) {
            var normalized: station_identity.StationIdentity = .{};
            _ = station_identity.normalizeStation(connect.address, &normalized) catch return rejected(.invalid_request);
            const source = if (self.desired_prefs) |*value| value.value else self.prefs.value;
            var proposed = clonePreferences(self.allocator, source) catch return error.OutOfMemory;
            errdefer proposed.deinit();
            var remembered_format: protocol.StreamFormat = .mp3;
            var display_name: []const u8 = "";
            for (proposed.value.stations) |station| if (std.mem.eql(u8, station.id, &normalized.id)) {
                remembered_format = station.streamFormat;
                display_name = station.name;
                break;
            };
            try preferences.pushRecent(proposed.arena.allocator(), &proposed.value, .{ .id = &normalized.id, .base = normalized.base(), .name = display_name, .streamFormat = remembered_format, .allowInsecureHttp = connect.allowInsecureHttp });
            proposed.value.activeStationId = proposed.value.stations[0].id;
            self.candidate_preferences = proposed;
            self.candidate_format = remembered_format;
        } else self.candidate_format = .mp3;
        self.candidate = candidate_connection.Transaction.begin(&self.host.selection, &self.host.http, connect) catch |err| {
            if (self.candidate_preferences) |*value| value.deinit();
            self.candidate_preferences = null;
            return if (err == error.CandidateBusy) rejected(.busy) else rejected(.invalid_request);
        };
        self.candidate_persists = persist;
        self.host.connection = .checking;
        self.host.revision += 1;
        return .{ .ok = true, .operationId = self.candidate.?.operation_id };
    }

    fn cancelCandidate(self: *Model, id: u64) !protocol.Accepted {
        const transaction = if (self.candidate) |*value| value else return rejected(.invalid_request);
        if (transaction.operation_id != id) return rejected(.invalid_request);
        if (try transaction.cancel()) |resolution| self.pending_resolution = resolution;
        return .{ .ok = true, .operationId = id };
    }

    fn consumeCandidate(context: *anyopaque, completion: *@import("host_effects.zig").Completion) anyerror!bool {
        const self: *Model = @ptrCast(@alignCast(context));
        const transaction = if (self.candidate) |*value| value else return false;
        if (!transaction.ownsHttp(completion.tag)) return false;
        if (try transaction.onHttp(completion)) |resolution| self.pending_resolution = resolution;
        return true;
    }

    fn resolveCandidate(self: *Model, services: sdk.platform.PlatformServices, resolution: selection.Resolution, now_ms: u64) !void {
        switch (resolution) {
            .stale => {},
            .failed => |status| {
                self.emit(status.operationId, false, status.errorCode);
                if (self.candidate) |*transaction| transaction.deinit();
                self.candidate = null;
                if (self.candidate_preferences) |*value| value.deinit();
                self.candidate_preferences = null;
                self.host.connection = connectionAfterFailure(self.host.selection.active_station != null, status.errorCode);
                self.host.revision += 1;
            },
            .activated => |activation| {
                const id = activation.operation_id;
                var credentials = self.candidate.?.takeActivationCredentials() orelse return error.MissingActivationCredentials;
                defer credentials.deinit();
                self.host.clearCredentials();
                self.host.basic = credentials.basic;
                credentials.basic = null;
                self.host.listener = credentials.listener;
                credentials.listener = null;
                self.host.allow_insecure_http = self.candidate.?.allow_insecure_http;
                self.host.activateWithFormat(services, activation, self.candidate_format, now_ms) catch {
                    self.host.clearCredentials();
                    self.failActivated(services, now_ms, id, "activation_failed");
                    return;
                };
                if (self.candidate_persists) {
                    if (self.desired_prefs) |*old| old.deinit();
                    self.desired_prefs = self.candidate_preferences.?;
                    self.candidate_preferences = null;
                    self.markDirty(now_ms);
                }
                self.candidate.?.deinit();
                self.candidate = null;
                self.emit(id, true, null);
            },
        }
    }

    fn onWorker(self: *Model, result: persistence.Result, services: sdk.platform.PlatformServices, now_ms: u64) !void {
        _ = services;
        if (self.import != null and result.operation_id == self.import.?.operation_id) {
            const kind: import_transaction.FileKind = switch (result.kind) {
                .read_legacy => .read_legacy,
                .backup => .backup,
                .save => .save,
                .load => return,
            };
            try self.driveImport(self.import.?.onFile(.{ .operation_id = result.operation_id, .kind = kind, .outcome = switch (result.outcome) {
                .ok => .ok,
                .miss => .miss,
                .cancelled => .cancelled,
                .failed => .failed,
            }, .bytes = result.bytes() }), now_ms);
            return;
        }
        if (self.forget_file_request) |request_id| if (self.forget != null and result.operation_id == self.forget.?.operation_id) {
            self.forget_file_request = null;
            if (!self.forget_marker_committed and result.outcome == .ok) {
                const marked = self.forget_marked_preferences orelse return error.MissingPreparedForgetMarker;
                self.forget_marked_preferences = null;
                self.prefs.deinit();
                self.prefs = marked;
                self.forget_marker_committed = true;
                self.host.revision += 1;
            }
            try self.driveForget(self.forget.?.onFile(.{ .operation_id = result.operation_id, .request_id = request_id, .outcome = if (result.outcome == .ok) .ok else if (result.outcome == .cancelled) .cancelled else .io_failed }), now_ms);
            return;
        };
        if (self.cold_load_id == result.operation_id) {
            self.cold_load_id = null;
            if (result.outcome == .ok) {
                const loaded = preferences.decode(self.allocator, result.bytes()) catch {
                    self.latest_persistence = failed(result.operation_id, "invalid_preferences");
                    self.host.revision += 1;
                    return;
                };
                self.prefs.deinit();
                self.prefs = loaded;
                self.host.volume = self.prefs.value.volume;
            }
            self.latest_persistence = if (result.outcome == .ok or result.outcome == .miss) succeeded(result.operation_id) else failed(result.operation_id, @tagName(result.failure));
            self.host.revision += 1;
            if (self.prefs.value.pendingRemoval) |station_id| {
                self.forget_reconcile_startup = true;
                _ = try self.beginForget(station_id);
                return;
            }
            try self.autoConnect();
            return;
        }
        if (self.save_id == result.operation_id) {
            self.save_id = null;
            const revision = self.save_revision orelse return error.MissingSaveRevision;
            self.save_revision = null;
            const ok = result.outcome == .ok;
            try self.save_policy.complete(revision, ok, now_ms);
            if (ok) {
                if (self.save_snapshot) |*committed| {
                    self.prefs.deinit();
                    self.prefs = committed.*;
                    self.save_snapshot = null;
                }
                if (self.save_policy.dirty_revision == null) if (self.desired_prefs) |*desired| {
                    desired.deinit();
                    self.desired_prefs = null;
                };
            } else if (self.save_snapshot) |*discard| {
                discard.deinit();
                self.save_snapshot = null;
            }
            self.latest_persistence = if (ok) succeeded(result.operation_id) else failed(result.operation_id, @tagName(result.failure));
            var retained: usize = 0;
            for (self.pending_preference_operations[0..self.pending_preference_count]) |operation| if (operation.revision <= revision) {
                self.emit(operation.id, ok, if (ok) null else @tagName(result.failure));
            } else {
                self.pending_preference_operations[retained] = operation;
                retained += 1;
            };
            self.pending_preference_count = retained;
            self.host.revision += 1;
        }
    }

    fn updatePreference(self: *Model, update: protocol.PreferenceUpdate, now_ms: u64) !protocol.Accepted {
        if (self.mutationBlocked()) return rejected(.busy);
        if (self.pending_preference_count == self.pending_preference_operations.len) return rejected(.busy);
        const id = try self.operationId();
        const source = if (self.desired_prefs) |*value| value.value else self.prefs.value;
        var proposed = try clonePreferences(self.allocator, source);
        errdefer proposed.deinit();
        const arena = proposed.arena.allocator();
        switch (update) {
            .themeOverride => |v| proposed.value.themeOverride = try arena.dupe(u8, v),
            .discordClientId => |v| proposed.value.discordClientId = try arena.dupe(u8, v),
            .discordEnabled => |v| proposed.value.discordEnabled = v,
            .notifyTrack => |v| proposed.value.notifyTrack = v,
        }
        preferences.validate(proposed.value) catch {
            proposed.deinit();
            return rejected(.invalid_request);
        };
        if (self.desired_prefs) |*old| old.deinit();
        self.desired_prefs = proposed;
        self.markDirty(now_ms);
        self.pending_preference_operations[self.pending_preference_count] = .{ .id = id, .revision = self.prefs_revision };
        self.pending_preference_count += 1;
        return .{ .ok = true, .operationId = id };
    }
    fn beginForget(self: *Model, station_id: []const u8) !protocol.Accepted {
        if (self.candidate != null or self.forget != null or self.import != null or self.cold_load_id != null or self.save_id != null or self.desired_prefs != null) return rejected(.busy);
        if (station_id.len != protocol.max_station_id_bytes) return rejected(.invalid_request);
        const id = try self.operationId();
        @memcpy(self.forget_station_id[0..station_id.len], station_id);
        self.forget_station_id_len = @intCast(station_id.len);
        self.forget_marker_committed = self.prefs.value.pendingRemoval != null;
        var marked_preferences: ?preferences.Decoded = null;
        if (!self.forget_marker_committed) {
            var marked = try clonePreferences(self.allocator, self.prefs.value);
            errdefer marked.deinit();
            marked.value.pendingRemoval = try marked.arena.allocator().dupe(u8, station_id);
            marked_preferences = marked;
        }
        self.forget = forget_transaction.Transaction.init(self.allocator);
        const step = self.forget.?.begin(id, self.prefs.value, station_id) catch |err| {
            self.forget.?.deinit();
            self.forget = null;
            if (marked_preferences) |*value| value.deinit();
            return if (err == error.Busy) rejected(.busy) else rejected(.invalid_request);
        };
        self.forget_marked_preferences = marked_preferences;
        self.latest_persistence = pending(id);
        self.host.revision += 1;
        try self.driveForget(step, 0);
        return .{ .ok = true, .operationId = id };
    }
    fn beginImport(self: *Model) !protocol.Accepted {
        if (self.candidate != null or self.forget != null or self.import != null or self.cold_load_id != null or self.save_id != null or self.desired_prefs != null or self.prefs.value.pendingRemoval != null) return rejected(.busy);
        const id = try self.operationId();
        self.import = import_transaction.Transaction.init(self.allocator);
        self.latest_persistence = pending(id);
        self.host.revision += 1;
        try self.driveImport(try self.import.?.begin(id), 0);
        return .{ .ok = true, .operationId = id };
    }
    fn driveImport(self: *Model, step: import_transaction.Step, now_ms: u64) !void {
        switch (step) {
            .file => |raw| {
                var command_value = raw;
                defer command_value.deinit();
                self.worker.submit(command_value.operation_id, switch (command_value.kind) {
                    .read_legacy => .read_legacy,
                    .backup => .backup,
                    .save => .save,
                }, command_value.bytes()) catch {
                    try self.driveImport(self.import.?.onFile(.{ .operation_id = command_value.operation_id, .kind = command_value.kind, .outcome = .failed }), now_ms);
                };
            },
            .vault => |raw| {
                var command_value = raw;
                defer command_value.deinit();
                const effect = switch (command_value.operation) {
                    .get => self.host.http.vaultGet(command_value.operation_id, self.host.selection.generation, command_value.key()),
                    .set => self.host.http.vaultSet(command_value.operation_id, self.host.selection.generation, command_value.key(), command_value.bytes()),
                } catch {
                    try self.driveImport(self.import.?.onVault(.{ .operation_id = command_value.operation_id, .request_id = command_value.request_id, .operation = command_value.operation, .outcome = .rejected }), now_ms);
                    return;
                };
                self.import_vault_request = .{ .effect = effect, .request_id = command_value.request_id, .operation = command_value.operation };
            },
            .succeeded => {
                const id = self.import.?.operation_id;
                var imported = try self.import.?.takeSucceeded();
                defer imported.deinit();
                var encoded: [preferences.max_output_bytes]u8 = undefined;
                defer std.crypto.secureZero(u8, &encoded);
                const bytes = try preferences.encode(imported.preferences, &encoded);
                const next = try preferences.decode(self.allocator, bytes);
                self.prefs.deinit();
                self.prefs = next;
                self.import.?.deinit();
                self.import = null;
                self.latest_persistence = succeeded(id);
                self.emit(id, true, null);
                self.host.revision += 1;
                if (self.host.selection.active_station == null) try self.autoConnect();
            },
            .failed => |reason| {
                const id = self.import.?.operation_id;
                self.import.?.deinit();
                self.import = null;
                self.latest_persistence = failed(id, @tagName(reason));
                self.emit(id, false, @tagName(reason));
                self.host.revision += 1;
            },
            .stale => {},
        }
    }
    fn driveForget(self: *Model, step: forget_transaction.Step, now_ms: u64) !void {
        switch (step) {
            .file => |command_value| {
                self.worker.submit(command_value.operation_id, .save, command_value.bytes()) catch {
                    try self.driveForget(self.forget.?.onFile(.{ .operation_id = command_value.operation_id, .request_id = command_value.request_id, .outcome = .io_failed }), now_ms);
                    return;
                };
                self.forget_file_request = command_value.request_id;
            },
            .vault => |command_value| {
                const effect = self.host.http.vaultDelete(command_value.operation_id, self.host.selection.generation, command_value.key()) catch {
                    try self.driveForget(self.forget.?.onVault(.{ .operation_id = command_value.operation_id, .request_id = command_value.request_id, .outcome = .rejected }), now_ms);
                    return;
                };
                self.forget_vault_request = .{ .effect = effect, .request_id = command_value.request_id };
            },
            .succeeded => {
                const id = self.forget.?.operation_id;
                const next = try self.forget.?.takeSucceeded();
                self.prefs.deinit();
                self.prefs = next;
                self.forget.?.deinit();
                self.forget = null;
                if (self.forget_marked_preferences) |*value| value.deinit();
                self.forget_marked_preferences = null;
                self.forget_marker_committed = false;
                self.forget_station_id_len = 0;
                self.emit(id, true, null);
                self.latest_persistence = succeeded(id);
                self.host.revision += 1;
                if (self.forget_reconcile_startup) {
                    self.forget_reconcile_startup = false;
                    try self.autoConnect();
                }
            },
            .failed => |reason| {
                const id = self.forget.?.operation_id;
                self.forget.?.deinit();
                self.forget = null;
                self.forget_reconcile_startup = false;
                self.forget_station_id_len = 0;
                self.emit(id, false, @tagName(reason));
                self.latest_persistence = failed(id, @tagName(reason));
                self.host.revision += 1;
            },
            .stale => {},
        }
    }
    fn markDirty(self: *Model, now_ms: u64) void {
        self.prefs_revision += 1;
        self.save_policy.dirty(self.prefs_revision, now_ms);
    }
    fn maybeSave(self: *Model, now_ms: u64) !void {
        const revision = self.save_policy.begin(now_ms) orelse return;
        const operation_id = try self.operationId();
        var bytes: [preferences.max_output_bytes]u8 = undefined;
        defer std.crypto.secureZero(u8, &bytes);
        const desired = self.desired_prefs orelse {
            try self.save_policy.complete(revision, true, now_ms);
            return;
        };
        const encoded = try preferences.encode(desired.value, &bytes);
        var snapshot_copy = try clonePreferences(self.allocator, desired.value);
        self.worker.submit(operation_id, .save, encoded) catch {
            snapshot_copy.deinit();
            try self.save_policy.complete(revision, false, now_ms);
            self.latest_persistence = failed(operation_id, "persistence_submit_failed");
            var retained: usize = 0;
            for (self.pending_preference_operations[0..self.pending_preference_count]) |operation| if (operation.revision <= revision) {
                self.emit(operation.id, false, "persistence_submit_failed");
            } else {
                self.pending_preference_operations[retained] = operation;
                retained += 1;
            };
            self.pending_preference_count = retained;
            self.host.revision += 1;
            return;
        };
        if (self.save_snapshot) |*old| old.deinit();
        self.save_snapshot = snapshot_copy;
        self.save_id = operation_id;
        self.save_revision = revision;
        self.latest_persistence = pending(operation_id);
        self.host.revision += 1;
    }
    fn operationId(self: *Model) !u64 {
        const id = self.host.selection.next_operation_id;
        if (id > protocol.max_operation_id) return error.OperationIdExhausted;
        self.host.selection.next_operation_id += 1;
        return id;
    }
    fn mutationBlocked(self: *const Model) bool {
        return self.candidate != null or self.forget != null or self.import != null or self.cold_load_id != null or self.prefs.value.pendingRemoval != null;
    }
    fn failActivated(self: *Model, services: sdk.platform.PlatformServices, now_ms: u64, id: u64, code: []const u8) void {
        if (self.candidate) |*transaction| transaction.deinit();
        self.candidate = null;
        if (self.candidate_preferences) |*value| value.deinit();
        self.candidate_preferences = null;
        self.host.disconnect(services, now_ms) catch {};
        self.host.connection = .@"error";
        self.host.revision += 1;
        self.emit(id, false, code);
    }
    fn consumeFormatDirty(self: *Model, now_ms: u64) !void {
        if (!self.host.format_dirty or self.mutationBlocked()) return;
        const desired = try self.ensureDesired();
        try setStationFormat(desired, self.host.selection.active_station, self.host.format);
        self.host.format_dirty = false;
        self.markDirty(now_ms);
    }
    fn autoConnect(self: *Model) !void {
        if (self.override_len > 0) {
            _ = try self.beginCandidate(.{ .address = self.override_storage[0..self.override_len], .basic = .keep, .listenerPassword = .keep, .allowInsecureHttp = false }, false);
            return;
        }
        const active = self.prefs.value.activeStationId orelse return;
        for (self.prefs.value.stations) |station| if (std.mem.eql(u8, station.id, active)) {
            self.host.format = station.streamFormat;
            _ = try self.beginCandidate(.{ .address = station.base, .basic = .keep, .listenerPassword = .keep, .allowInsecureHttp = station.allowInsecureHttp }, true);
            return;
        };
    }
    fn ensureDesired(self: *Model) !*preferences.Decoded {
        if (self.desired_prefs == null) self.desired_prefs = try clonePreferences(self.allocator, self.prefs.value);
        return &self.desired_prefs.?;
    }
    fn emit(self: *Model, id: u64, ok: bool, code: ?[]const u8) void {
        if (self.operation_count == self.operation_queue.len) {
            self.operation_queue[self.operation_head] = null;
            self.operation_head = (self.operation_head + 1) % self.operation_queue.len;
            self.operation_count -= 1;
        }
        const tail = (self.operation_head + self.operation_count) % self.operation_queue.len;
        self.operation_queue[tail] = .{ .operationId = id, .status = if (ok) .succeeded else .failed, .errorCode = code };
        self.operation_count += 1;
    }
};

fn rejected(reason: protocol.AcceptedError) protocol.Accepted {
    return .{ .ok = false, .@"error" = reason };
}
fn pending(id: u64) protocol.OperationStatus {
    return .{ .operationId = id, .status = .pending };
}
fn succeeded(id: u64) protocol.OperationStatus {
    return .{ .operationId = id, .status = .succeeded };
}
fn failed(id: u64, code: ?[]const u8) protocol.OperationStatus {
    return .{ .operationId = id, .status = .failed, .errorCode = code };
}
fn connectionAfterFailure(has_active: bool, code: ?[]const u8) protocol.Connection {
    if (has_active) return .ready;
    const value = code orelse return .@"error";
    if (std.mem.eql(u8, value, "cancelled")) return .none;
    if (std.mem.eql(u8, value, "auth-required")) return .@"auth-required";
    if (std.mem.eql(u8, value, "vault-unavailable")) return .@"vault-unavailable";
    return .@"error";
}
fn clonePreferences(allocator: std.mem.Allocator, value: preferences.Preferences) !preferences.Decoded {
    var storage: [preferences.max_output_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &storage);
    return preferences.decode(allocator, try preferences.encode(value, &storage));
}
fn setStationFormat(decoded: *preferences.Decoded, active: ?@import("station_identity.zig").StationIdentity, format: protocol.StreamFormat) !void {
    const identity = active orelse return;
    const stations = try decoded.arena.allocator().dupe(preferences.Station, decoded.value.stations);
    for (stations) |*station| if (std.mem.eql(u8, station.id, &identity.id)) {
        station.streamFormat = format;
        break;
    };
    decoded.value.stations = stations;
}

test "model init is I/O-free and deinit stops its unopened worker" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/foundation-model-hermetic-home");
    var model = try Model.init(std.testing.allocator, &env);
    try std.testing.expect(!model.started);
    try std.testing.expect(model.worker_alive);
    model.deinit();
}

test "desired preferences remain invisible until a successful save acknowledgement" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/foundation-model-hermetic-home");
    var model = try Model.init(std.testing.allocator, &env);
    defer model.deinit();
    const desired = try model.ensureDesired();
    desired.value.notifyTrack = true;
    model.markDirty(10);
    try std.testing.expect(!model.snapshot(10).preferences.notifyTrack);
    var committed = try clonePreferences(std.testing.allocator, desired.value);
    model.prefs.deinit();
    model.prefs = committed;
    committed = undefined;
    try std.testing.expect(model.snapshot(10).preferences.notifyTrack);
}

test "operation queue stays bounded and reports the newest terminal results" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/foundation-model-hermetic-home");
    var model = try Model.init(std.testing.allocator, &env);
    defer model.deinit();
    for (1..11) |id| model.emit(id, true, null);
    try std.testing.expectEqual(@as(u64, 3), model.nextOperation().?.operationId);
    var last: u64 = 0;
    while (model.nextOperation()) |result| last = result.operationId;
    try std.testing.expectEqual(@as(u64, 10), last);
}

test "worker acknowledgement publishes staged preferences and advances snapshot revision" {
    var root = std.testing.tmpDir(.{});
    defer root.cleanup();
    var config_path_storage: [256]u8 = undefined;
    const config_path = try std.fmt.bufPrint(&config_path_storage, ".zig-cache/tmp/{s}", .{root.sub_path});
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", config_path);
    try env.put("XDG_CONFIG_HOME", config_path);
    var model = try Model.init(std.testing.allocator, &env);
    defer model.deinit();

    const original_revision = model.snapshot(0).revision;
    const desired = try model.ensureDesired();
    desired.value.notifyTrack = true;
    model.markDirty(0);
    try model.maybeSave(store.debounce_ms);
    try std.testing.expect(!model.snapshot(store.debounce_ms).preferences.notifyTrack);
    var result: persistence.Result = result: {
        for (0..5000) |_| {
            if (model.worker.poll()) |ready| break :result ready;
            std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
        }
        return error.TestTimedOut;
    };
    defer result.deinit();
    try model.onWorker(result, .{}, store.debounce_ms + 1);
    const after = model.snapshot(store.debounce_ms + 1);
    try std.testing.expect(after.preferences.notifyTrack);
    try std.testing.expect(after.revision > original_revision);
    try std.testing.expectEqual(protocol.OperationState.succeeded, after.operations.persistence.?.status);
}

test "preference operations straddling a save complete with their own revision" {
    var root = std.testing.tmpDir(.{});
    defer root.cleanup();
    var path_storage: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, ".zig-cache/tmp/{s}", .{root.sub_path});
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", path);
    try env.put("XDG_CONFIG_HOME", path);
    var model = try Model.init(std.testing.allocator, &env);
    defer model.deinit();

    const first = try model.updatePreference(.{ .notifyTrack = true }, 0);
    try model.maybeSave(store.debounce_ms);
    const second = try model.updatePreference(.{ .themeOverride = "night" }, store.debounce_ms + 1);
    var result = try waitWorker(model.worker);
    try model.onWorker(result, .{}, store.debounce_ms + 2);
    result.deinit();
    try std.testing.expectEqual(first.operationId.?, model.nextOperation().?.operationId);
    try std.testing.expect(model.nextOperation() == null);
    try std.testing.expectEqual(@as(usize, 1), model.pending_preference_count);
    try std.testing.expectEqual(second.operationId.?, model.pending_preference_operations[0].id);
    try std.testing.expectEqualStrings("", model.snapshot(0).preferences.themeOverride);

    try model.maybeSave(2 * store.debounce_ms + 1);
    result = try waitWorker(model.worker);
    try model.onWorker(result, .{}, 2 * store.debounce_ms + 2);
    result.deinit();
    try std.testing.expectEqual(second.operationId.?, model.nextOperation().?.operationId);
    try std.testing.expectEqualStrings("night", model.snapshot(0).preferences.themeOverride);
}

test "failed forget retains its acknowledged marker blocks mutation and permits retry" {
    var root = std.testing.tmpDir(.{});
    defer root.cleanup();
    var path_storage: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, ".zig-cache/tmp/{s}", .{root.sub_path});
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", path);
    try env.put("XDG_CONFIG_HOME", path);
    var model = try Model.init(std.testing.allocator, &env);
    defer model.deinit();
    var identity: @import("station_identity.zig").StationIdentity = .{};
    _ = try @import("station_identity.zig").normalizeStation("radio.example", &identity);
    try preferences.pushRecent(model.prefs.arena.allocator(), &model.prefs.value, .{ .id = &identity.id, .base = identity.base(), .name = "Radio" });
    model.prefs.value.activeStationId = model.prefs.value.stations[0].id;

    const accepted = try model.beginForget(&identity.id);
    var result = try waitWorker(model.worker);
    model.host.http.stopped = true;
    try model.onWorker(result, .{}, 1);
    result.deinit();
    try std.testing.expectEqualStrings(&identity.id, model.prefs.value.pendingRemoval.?);
    try std.testing.expect(model.forget == null);
    try std.testing.expect(!(try model.beginImport()).ok);
    model.host.format_dirty = true;
    try model.consumeFormatDirty(2);
    try std.testing.expect(model.host.format_dirty);
    model.host.http.stopped = false;
    const retry = try model.beginForget(&identity.id);
    try std.testing.expect(retry.ok);
    try std.testing.expectEqual(accepted.operationId.? + 1, retry.operationId.?);
}

test "cold legacy import writes and verifies a vault miss through hermetic SDK backing" {
    var root = std.testing.tmpDir(.{});
    defer root.cleanup();
    var path_storage: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, ".zig-cache/tmp/{s}", .{root.sub_path});
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", path);
    try env.put("XDG_CONFIG_HOME", path);
    var model = try Model.init(std.testing.allocator, &env);
    defer model.deinit();

    var legacy_path_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const legacy_path = try sdk.app_dirs.resolveOne(.{ .name = "subwave-player" }, sdk.app_dirs.currentPlatform(), sdk.debug.envFromMap(&env), .config, &legacy_path_storage);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, legacy_path);
    var legacy_dir = try std.Io.Dir.cwd().openDir(std.testing.io, legacy_path, .{});
    defer legacy_dir.close(std.testing.io);
    var legacy_file = try legacy_dir.createFile(std.testing.io, "settings.json", .{});
    try legacy_file.writeStreamingAll(std.testing.io, "{\"station\":\"https://user:pass@radio.example\",\"stationName\":\"Radio\"}");
    legacy_file.close(std.testing.io);

    var platform = sdk.platform.NullPlatform.init(.{});
    defer platform.deinit();
    var binding = platform.platform();
    model.host.http.effects.bindCredentialsStore(.{ .services = &binding.services, .service = "dev.subwave.model-import-test", .permitted = true });
    const accepted = try model.beginImport();
    try std.testing.expect(accepted.ok);
    for (0..10_000) |_| {
        try model.drain(binding.services, 1);
        if (model.import == null) break;
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(model.import == null);
    try std.testing.expect(model.prefs.value.legacyImport.completed);
    try std.testing.expectEqual(@as(usize, 1), model.prefs.value.stations.len);
    try std.testing.expect(std.mem.startsWith(u8, platform.lastCredentialAccount(), "basic:"));
    const result = model.nextOperation() orelse return error.MissingImportResult;
    try std.testing.expectEqual(accepted.operationId.?, result.operationId);
    try std.testing.expectEqual(.succeeded, result.status);
}

test "candidate preference allocation fails before selection or vault mutation" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/foundation-model-hermetic-home");
    var model = try Model.init(std.testing.allocator, &env);
    defer model.deinit();
    var active: station_identity.StationIdentity = .{};
    _ = try station_identity.normalizeStation("active.example", &active);
    model.host.selection.active_station = active;
    try preferences.pushRecent(model.prefs.arena.allocator(), &model.prefs.value, .{ .id = &active.id, .base = active.base(), .name = "Active" });
    model.prefs.value.activeStationId = model.prefs.value.stations[0].id;

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    model.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, model.beginCandidate(.{ .address = "candidate.example", .basic = .keep, .listenerPassword = .keep, .allowInsecureHttp = false }, true));
    try std.testing.expect(model.candidate == null);
    try std.testing.expect(model.candidate_preferences == null);
    try std.testing.expect(model.host.selection.candidate == null);
    try std.testing.expectEqualStrings(active.base(), model.host.selection.active_station.?.base());

    var forget_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    model.allocator = forget_failing.allocator();
    try std.testing.expectError(error.OutOfMemory, model.beginForget(&active.id));
    try std.testing.expect(model.forget == null);
    try std.testing.expect(model.forget_marked_preferences == null);
}

fn waitWorker(worker: *persistence.Worker) !persistence.Result {
    for (0..5000) |_| {
        if (worker.poll()) |result| return result;
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    return error.TestTimedOut;
}
