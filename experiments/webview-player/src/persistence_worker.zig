//! One-slot asynchronous preferences filesystem worker.
const std = @import("std");
const preferences = @import("preferences.zig");
const store = @import("preferences_store.zig");

pub const Kind = enum { load, save, read_legacy, backup };
pub const Outcome = enum { ok, miss, cancelled, failed };
pub const Failure = enum { none, invalid, too_large, backup_conflict, io_failed };
pub const Result = struct {
    operation_id: u64,
    kind: Kind,
    outcome: Outcome,
    failure: Failure = .none,
    durability: ?store.Durability = null,
    storage: [preferences.max_input_bytes]u8 = @splat(0),
    len: usize = 0,
    pub fn bytes(self: *const Result) []const u8 {
        return self.storage[0..self.len];
    }
    pub fn deinit(self: *Result) void {
        std.crypto.secureZero(u8, &self.storage);
        self.len = 0;
        self.failure = .none;
        self.durability = null;
    }
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    threaded: std.Io.Threaded,
    new_dir_storage: [std.Io.Dir.max_path_bytes]u8 = undefined,
    new_dir_len: usize = 0,
    legacy_dir_storage: [std.Io.Dir.max_path_bytes]u8 = undefined,
    legacy_dir_len: usize = 0,
    input: [preferences.max_input_bytes]u8 = @splat(0),
    input_len: usize = 0,
    result: Result = .{ .operation_id = 0, .kind = .load, .outcome = .failed },
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    future: ?std.Io.Future(void) = null,
    stopped: bool = false,

    pub fn init(allocator: std.mem.Allocator, new_dir_path: []const u8, legacy_dir_path: []const u8) !*Worker {
        if (new_dir_path.len == 0 or legacy_dir_path.len == 0 or new_dir_path.len > std.Io.Dir.max_path_bytes or legacy_dir_path.len > std.Io.Dir.max_path_bytes) return error.InvalidPath;
        const self = try allocator.create(Worker);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .threaded = std.Io.Threaded.init(allocator, .{}) };
        @memcpy(self.new_dir_storage[0..new_dir_path.len], new_dir_path);
        self.new_dir_len = new_dir_path.len;
        @memcpy(self.legacy_dir_storage[0..legacy_dir_path.len], legacy_dir_path);
        self.legacy_dir_len = legacy_dir_path.len;
        return self;
    }
    pub fn submit(self: *Worker, operation_id: u64, kind: Kind, bytes: []const u8) !void {
        if (self.stopped) return error.Stopped;
        if (self.future != null) return error.Busy;
        if (operation_id == 0 or bytes.len > self.input.len) return error.InvalidRequest;
        if ((kind == .save or kind == .backup) != (bytes.len > 0)) return error.InvalidRequest;
        std.crypto.secureZero(u8, &self.input);
        @memcpy(self.input[0..bytes.len], bytes);
        self.input_len = bytes.len;
        self.result = .{ .operation_id = operation_id, .kind = kind, .outcome = .failed };
        self.done.store(false, .release);
        self.future = std.Io.concurrent(self.threaded.io(), task, .{self}) catch {
            self.wipeJob();
            return error.ConcurrencyUnavailable;
        };
    }
    pub fn poll(self: *Worker) ?Result {
        if (self.future == null or !self.done.load(.acquire)) return null;
        self.future.?.await(self.threaded.io());
        self.future = null;
        const result = self.result;
        self.wipeJob();
        return result;
    }
    pub fn stop(self: *Worker) void {
        if (self.stopped) return;
        self.stopped = true;
        if (self.future) |*future| {
            future.cancel(self.threaded.io());
            self.future = null;
        }
        self.wipeJob();
        self.threaded.deinit();
        const allocator = self.allocator;
        std.crypto.secureZero(u8, self.new_dir_storage[0..self.new_dir_len]);
        std.crypto.secureZero(u8, self.legacy_dir_storage[0..self.legacy_dir_len]);
        allocator.destroy(self);
    }

    fn task(self: *Worker) void {
        defer self.done.store(true, .release);
        self.run() catch |err| {
            self.result.outcome = if (err == error.Canceled) .cancelled else .failed;
            self.result.failure = classify(err);
            self.result.len = 0;
            std.crypto.secureZero(u8, &self.result.storage);
        };
    }
    fn run(self: *Worker) !void {
        const io = self.threaded.io();
        switch (self.result.kind) {
            .load => {
                var dir = openDir(io, self.newDir()) catch |err| if (isMissing(err)) {
                    self.result.outcome = .miss;
                    return;
                } else return err;
                defer dir.close(io);
                const bytes = store.readPreferencesBytes(io, dir, &self.result.storage) catch |err| if (isMissing(err)) {
                    self.result.outcome = .miss;
                    return;
                } else return err;
                var decoded = preferences.decode(self.allocator, bytes) catch return error.InvalidPreferences;
                decoded.deinit();
                self.result.len = bytes.len;
            },
            .save => {
                var decoded = preferences.decode(self.allocator, self.input[0..self.input_len]) catch return error.InvalidPreferences;
                defer decoded.deinit();
                var dir = try createDir(io, self.newDir());
                defer dir.close(io);
                self.result.durability = try store.save(io, dir, decoded.value, .{});
            },
            .read_legacy => {
                var dir = openDir(io, self.legacyDir()) catch |err| if (isMissing(err)) {
                    self.result.outcome = .miss;
                    return;
                } else return err;
                defer dir.close(io);
                const bytes = store.readLegacyBytes(io, dir, &self.result.storage) catch |err| if (isMissing(err)) {
                    self.result.outcome = .miss;
                    return;
                } else return err;
                self.result.len = bytes.len;
            },
            .backup => {
                var dir = try createDir(io, self.newDir());
                defer dir.close(io);
                _ = try store.backupBytesOnce(io, dir, self.input[0..self.input_len]);
            },
        }
        self.result.outcome = .ok;
    }
    fn newDir(self: *const Worker) []const u8 {
        return self.new_dir_storage[0..self.new_dir_len];
    }
    fn legacyDir(self: *const Worker) []const u8 {
        return self.legacy_dir_storage[0..self.legacy_dir_len];
    }
    fn wipeJob(self: *Worker) void {
        std.crypto.secureZero(u8, &self.input);
        self.input_len = 0;
        std.crypto.secureZero(u8, &self.result.storage);
        self.result.len = 0;
        self.done.store(false, .release);
    }
};

fn openDir(io: std.Io, path: []const u8) !std.Io.Dir {
    return if (std.fs.path.isAbsolute(path)) std.Io.Dir.openDirAbsolute(io, path, .{}) else std.Io.Dir.cwd().openDir(io, path, .{});
}
fn createDir(io: std.Io, path: []const u8) !std.Io.Dir {
    if (std.fs.path.isAbsolute(path)) {
        try std.Io.Dir.cwd().createDirPath(io, path);
        return std.Io.Dir.openDirAbsolute(io, path, .{});
    }
    return std.Io.Dir.cwd().createDirPathOpen(io, path, .{});
}
fn isMissing(err: anyerror) bool {
    return err == error.FileNotFound or err == error.PathNotFound;
}
fn classify(err: anyerror) Failure {
    return if (err == error.BackupConflict) .backup_conflict else if (err == error.PreferencesTooLarge or err == error.LegacySettingsTooLarge) .too_large else if (err == error.InvalidPreferences or err == error.UnsupportedPreferencesVersion or err == error.SyntaxError) .invalid else .io_failed;
}

test "worker save cold load legacy read backup and busy slot" {
    var root = std.testing.tmpDir(.{});
    defer root.cleanup();
    var new_path: [128]u8 = undefined;
    var legacy_path: [128]u8 = undefined;
    const new_dir = try std.fmt.bufPrint(&new_path, ".zig-cache/tmp/{s}/new", .{root.sub_path});
    const legacy_dir = try std.fmt.bufPrint(&legacy_path, ".zig-cache/tmp/{s}/legacy", .{root.sub_path});
    try std.Io.Dir.cwd().createDirPath(std.testing.io, legacy_dir);
    var legacy = try std.Io.Dir.cwd().openDir(std.testing.io, legacy_dir, .{});
    defer legacy.close(std.testing.io);
    const old = "{\"volume\":0.4}";
    var file = try legacy.createFile(std.testing.io, "settings.json", .{});
    try file.writeStreamingAll(std.testing.io, old);
    file.close(std.testing.io);

    const worker = try Worker.init(std.testing.allocator, new_dir, legacy_dir);
    defer worker.stop();
    try worker.submit(1, .load, "");
    try std.testing.expectError(error.Busy, worker.submit(2, .read_legacy, ""));
    var result = try wait(worker);
    try std.testing.expectEqual(Outcome.miss, result.outcome);
    result.deinit();
    try worker.submit(2, .read_legacy, "");
    result = try wait(worker);
    try std.testing.expectEqualStrings(old, result.bytes());
    result.deinit();
    try worker.submit(3, .backup, old);
    result = try wait(worker);
    try std.testing.expectEqual(Outcome.ok, result.outcome);
    result.deinit();
    const settings = "{\"version\":2,\"volume\":0.7}";
    try worker.submit(4, .save, settings);
    result = try wait(worker);
    try std.testing.expectEqual(Outcome.ok, result.outcome);
    try std.testing.expect(result.durability != null);
    result.deinit();
    try worker.submit(5, .load, "");
    result = try wait(worker);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes(), "\"volume\":0.7") != null);
    result.deinit();
}

test "stop joins an in-flight job and permits temporary directory cleanup" {
    var root = std.testing.tmpDir(.{});
    defer root.cleanup();
    var new_path: [128]u8 = undefined;
    var legacy_path: [128]u8 = undefined;
    const new_dir = try std.fmt.bufPrint(&new_path, ".zig-cache/tmp/{s}/new", .{root.sub_path});
    const legacy_dir = try std.fmt.bufPrint(&legacy_path, ".zig-cache/tmp/{s}/legacy", .{root.sub_path});
    const worker = try Worker.init(std.testing.allocator, new_dir, legacy_dir);
    try worker.submit(1, .backup, "sensitive-legacy-bytes" ** 200);
    worker.stop();
}

fn wait(worker: *Worker) !Result {
    for (0..5000) |_| {
        if (worker.poll()) |result| return result;
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    return error.TestTimedOut;
}
