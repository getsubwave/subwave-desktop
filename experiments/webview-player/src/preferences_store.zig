//! Worker-only, directory-relative persistence for bounded nonsecret preferences.
const std = @import("std");
const builtin = @import("builtin");
const preferences = @import("preferences.zig");

pub const filename = "settings.v2.json";
pub const legacy_backup_filename = "settings.legacy.backup.json";
pub const debounce_ms: u64 = 800;

pub const Durability = enum {
    file_and_directory,
    file_only,
};

pub const FailurePoint = enum { none, before_file_sync, before_replace, after_replace_before_directory_sync };
pub const WriteOptions = struct { failure_point: FailurePoint = .none };

pub const SavePolicy = struct {
    saved_revision: u64 = 0,
    dirty_revision: ?u64 = null,
    in_flight_revision: ?u64 = null,
    due_at_ms: ?u64 = null,

    pub fn dirty(self: *SavePolicy, revision: u64, now_ms: u64) void {
        if (revision <= self.saved_revision) return;
        if (self.dirty_revision) |dirty_revision| if (revision <= dirty_revision) return;
        self.dirty_revision = revision;
        self.due_at_ms = now_ms +| debounce_ms;
    }

    pub fn begin(self: *SavePolicy, now_ms: u64) ?u64 {
        if (self.in_flight_revision != null) return null;
        const revision = self.dirty_revision orelse return null;
        if (now_ms < (self.due_at_ms orelse return null)) return null;
        self.in_flight_revision = revision;
        return revision;
    }

    pub fn complete(self: *SavePolicy, revision: u64, succeeded: bool, now_ms: u64) !void {
        if (self.in_flight_revision != revision) return error.RevisionMismatch;
        self.in_flight_revision = null;
        if (succeeded) {
            self.saved_revision = @max(self.saved_revision, revision);
            if (self.dirty_revision == revision) {
                self.dirty_revision = null;
                self.due_at_ms = null;
            }
        } else {
            if (self.dirty_revision == null or revision > self.dirty_revision.?) self.dirty_revision = revision;
            self.due_at_ms = now_ms;
        }
    }
};

/// Synchronous and blocking: call only from the host's persistence worker.
pub fn save(io: std.Io, dir: std.Io.Dir, value: preferences.Preferences, options: WriteOptions) !Durability {
    var encoded_storage: [preferences.max_output_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &encoded_storage);
    const encoded = try preferences.encode(value, &encoded_storage);
    return atomicWrite(io, dir, filename, encoded, true, options);
}

/// Synchronous and blocking: call only from the host's persistence worker.
pub fn load(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !preferences.Decoded {
    const bytes = try readBounded(allocator, io, dir, filename, preferences.max_input_bytes);
    defer {
        std.crypto.secureZero(u8, bytes);
        allocator.free(bytes);
    }
    return preferences.decode(allocator, bytes);
}

pub const BackupResult = enum { created, already_exists };

/// Copies a bounded legacy source byte-for-byte into an owner-only backup.
/// The destination is create-once and is never replaced.
pub fn backupBytesOnce(io: std.Io, backup_dir: std.Io.Dir, bytes: []const u8) !BackupResult {
    return backupBytesOnceWithOptions(io, backup_dir, bytes, .{});
}

fn backupBytesOnceWithOptions(io: std.Io, backup_dir: std.Io.Dir, bytes: []const u8, options: WriteOptions) !BackupResult {
    if (bytes.len > preferences.max_input_bytes) return error.PreferencesTooLarge;
    _ = atomicWrite(io, backup_dir, legacy_backup_filename, bytes, false, options) catch |err| switch (err) {
        error.PathAlreadyExists => {
            var existing: [preferences.max_input_bytes]u8 = undefined;
            defer std.crypto.secureZero(u8, &existing);
            const found = try readInto(io, backup_dir, legacy_backup_filename, &existing);
            if (!std.mem.eql(u8, found, bytes)) return error.BackupConflict;
            // A previous create may have linked the file and then failed before
            // syncing the directory. Every idempotent retry must finish that
            // durability boundary before reporting success.
            _ = try syncDirectory(io, backup_dir);
            return .already_exists;
        },
        else => return err,
    };
    return .created;
}

pub fn readPreferencesBytes(io: std.Io, dir: std.Io.Dir, output: []u8) ![]const u8 {
    return readInto(io, dir, filename, output);
}
pub fn readLegacyBytes(io: std.Io, dir: std.Io.Dir, output: []u8) ![]const u8 {
    return readInto(io, dir, "settings.json", output);
}

fn readInto(io: std.Io, dir: std.Io.Dir, name: []const u8, output: []u8) ![]const u8 {
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > output.len) return error.PreferencesTooLarge;
    var scratch: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &scratch);
    var reader = file.reader(io, &scratch);
    const count: usize = @intCast(stat.size);
    try reader.interface.readSliceAll(output[0..count]);
    _ = reader.interface.takeByte() catch |err| switch (err) {
        error.EndOfStream => return output[0..count],
        else => return err,
    };
    return error.PreferencesTooLarge;
}

fn readBounded(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8, max: usize) ![]u8 {
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > max) return error.PreferencesTooLarge;
    var storage: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &storage);
    var reader = file.reader(io, &storage);
    const bytes = reader.interface.allocRemaining(allocator, .limited(max + 1)) catch |err| switch (err) {
        error.StreamTooLong => return error.PreferencesTooLarge,
        else => return err,
    };
    if (bytes.len > max) {
        std.crypto.secureZero(u8, bytes);
        allocator.free(bytes);
        return error.PreferencesTooLarge;
    }
    return bytes;
}

fn atomicWrite(io: std.Io, dir: std.Io.Dir, name: []const u8, bytes: []const u8, replace: bool, options: WriteOptions) !Durability {
    var atomic = try dir.createFileAtomic(io, name, .{ .permissions = ownerOnlyPermissions(), .replace = replace });
    defer atomic.deinit(io);
    var buffer: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    var writer = atomic.file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.flush();
    if (options.failure_point == .before_file_sync) return error.InjectedFailure;
    try atomic.file.sync(io);
    if (options.failure_point == .before_replace) return error.InjectedFailure;
    if (replace) try atomic.replace(io) else try atomic.link(io);
    if (options.failure_point == .after_replace_before_directory_sync) return error.InjectedFailure;
    return syncDirectory(io, dir);
}

fn ownerOnlyPermissions() std.Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_file else @enumFromInt(0o600);
}

fn syncDirectory(io: std.Io, dir: std.Io.Dir) !Durability {
    return switch (builtin.os.tag) {
        .linux, .macos, .freebsd, .openbsd, .netbsd, .dragonfly, .illumos => blk: {
            // Dir handles may be O_PATH on Linux and cannot be fsynced. Open
            // the directory itself as a file relative to the supplied handle.
            const file = try dir.openFile(io, ".", .{});
            defer file.close(io);
            try file.sync(io);
            break :blk .file_and_directory;
        },
        else => .file_only,
    };
}

fn samplePreferences() !struct { identity: @import("station_identity.zig").StationIdentity, value: preferences.Preferences } {
    const identity_mod = @import("station_identity.zig");
    var identity: identity_mod.StationIdentity = .{};
    _ = try identity_mod.normalizeStation("radio.example", &identity);
    return .{ .identity = identity, .value = .{} };
}

test "atomic save and cold read round trip with owner-only file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try samplePreferences();
    const station = preferences.Station{ .id = &fixture.identity.id, .base = fixture.identity.base(), .name = "Radio" };
    fixture.value.stations = (&[_]preferences.Station{station})[0..];
    fixture.value.activeStationId = &fixture.identity.id;
    _ = try save(std.testing.io, tmp.dir, fixture.value, .{});
    var decoded = try load(std.testing.allocator, std.testing.io, tmp.dir);
    defer decoded.deinit();
    try std.testing.expectEqualStrings("Radio", decoded.value.stations[0].name);
    if (builtin.os.tag != .windows) {
        const stat = try tmp.dir.statFile(std.testing.io, filename, .{});
        try std.testing.expectEqual(@as(u32, 0o600), @intFromEnum(stat.permissions) & 0o777);
    }
}

test "invalid save and injected rename-boundary failure preserve last good file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var good: preferences.Preferences = .{ .themeOverride = "good" };
    _ = try save(std.testing.io, tmp.dir, good, .{});
    var invalid = good;
    invalid.volume = 2;
    try std.testing.expectError(error.InvalidPreferences, save(std.testing.io, tmp.dir, invalid, .{}));
    good.themeOverride = "replacement";
    try std.testing.expectError(error.InjectedFailure, save(std.testing.io, tmp.dir, good, .{ .failure_point = .before_replace }));
    var decoded = try load(std.testing.allocator, std.testing.io, tmp.dir);
    defer decoded.deinit();
    try std.testing.expectEqualStrings("good", decoded.value.themeOverride);
}

test "cold read rejects oversized storage without overwriting it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, filename, .{});
    defer file.close(std.testing.io);
    const bytes = "x" ** (preferences.max_input_bytes + 1);
    try file.writeStreamingAll(std.testing.io, bytes);
    try std.testing.expectError(error.PreferencesTooLarge, load(std.testing.allocator, std.testing.io, tmp.dir));
    try std.testing.expectEqual(@as(u64, bytes.len), (try file.stat(std.testing.io)).size);
}

test "legacy backup is byte exact create-once and conflicts on changed bytes" {
    var backup = std.testing.tmpDir(.{});
    defer backup.cleanup();
    const original = "{\"url\":\"https://u:p@example.test\"}\n";
    try std.testing.expectEqual(BackupResult.created, try backupBytesOnce(std.testing.io, backup.dir, original));
    try std.testing.expectEqual(BackupResult.already_exists, try backupBytesOnce(std.testing.io, backup.dir, original));
    try std.testing.expectError(error.BackupConflict, backupBytesOnce(std.testing.io, backup.dir, "changed"));
    const copied = try readBounded(std.testing.allocator, std.testing.io, backup.dir, legacy_backup_filename, preferences.max_input_bytes);
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings(original, copied);
}

test "backup retry after link completes the directory durability boundary" {
    var backup = std.testing.tmpDir(.{});
    defer backup.cleanup();
    const original = "legacy bytes with credentials";
    try std.testing.expectError(error.InjectedFailure, backupBytesOnceWithOptions(std.testing.io, backup.dir, original, .{ .failure_point = .after_replace_before_directory_sync }));
    try std.testing.expectEqual(BackupResult.already_exists, try backupBytesOnce(std.testing.io, backup.dir, original));
    const copied = try readBounded(std.testing.allocator, std.testing.io, backup.dir, legacy_backup_filename, preferences.max_input_bytes);
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings(original, copied);
}

test "save policy serializes writes and persists latest dirty revision" {
    var policy: SavePolicy = .{};
    policy.dirty(1, 100);
    try std.testing.expect(policy.begin(899) == null);
    try std.testing.expectEqual(@as(?u64, 1), policy.begin(900));
    policy.dirty(2, 950);
    policy.dirty(1, 1_200); // An older notification cannot postpone revision 2.
    try std.testing.expect(policy.begin(10_000) == null);
    try policy.complete(1, true, 1_000);
    try std.testing.expect(policy.begin(1_749) == null);
    try std.testing.expectEqual(@as(?u64, 2), policy.begin(1_750));
    try policy.complete(2, false, 1_800);
    try std.testing.expectEqual(@as(?u64, 2), policy.begin(1_800));
}
