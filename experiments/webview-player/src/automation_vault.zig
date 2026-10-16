//! Persistent synthetic credential store for explicitly enabled GUI automation.
const std = @import("std");
const sdk = @import("native_sdk");

pub const Vault = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    mutex: std.atomic.Mutex = .unlocked,
    lifetime_mutex: std.atomic.Mutex = .unlocked,
    active_calls: usize = 0,
    destroy_requested: bool = false,
    abandoned: bool = false,
    locked: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, temp_dir: []const u8) !*Vault {
        if (!approvedPath(temp_dir)) return error.UnapprovedAutomationVault;
        // The harness creates the directory. Opening it before validation makes
        // this function read-only until containment has been proven.
        var dir = std.Io.Dir.openDirAbsolute(io, temp_dir, .{}) catch return error.UnapprovedAutomationVault;
        errdefer dir.close(io);
        var canonical_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const canonical_len = dir.realPath(io, &canonical_storage) catch return error.UnapprovedAutomationVault;
        if (!approvedPath(canonical_storage[0..canonical_len])) return error.UnapprovedAutomationVault;
        const self = try allocator.create(Vault);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .dir = dir,
        };
        return self;
    }

    pub fn deinit(self: *Vault) void {
        self.lockLifetime();
        self.destroy_requested = true;
        // After the SDK abandons a worker, it may not have entered our
        // callback yet. Keep the callback context and directory handle for
        // process lifetime; an active-call count cannot cover that pre-entry
        // scheduling window.
        const finalize_now = !self.abandoned and self.active_calls == 0;
        self.lifetime_mutex.unlock();
        if (finalize_now) self.finalize();
    }

    /// Test-only fault control. Locked operations map through the SDK adapter
    /// to its closed `.locked` outcome.
    pub fn setLocked(self: *Vault, locked: bool) void {
        self.lock();
        defer self.mutex.unlock();
        self.locked = locked;
    }

    pub fn services(self: *Vault) sdk.platform.PlatformServices {
        return .{
            .context = self,
            .set_credential_fn = setCredential,
            .get_credential_fn = getCredential,
            .delete_credential_fn = deleteCredential,
            .note_blocking_call_abandoned_fn = noteBlockingCallAbandoned,
        };
    }

    fn setCredential(context: ?*anyopaque, credential: sdk.platform.Credential) anyerror!void {
        const self: *Vault = @ptrCast(@alignCast(context orelse return error.CredentialStoreFailed));
        if (!self.enter()) return error.CredentialStoreLocked;
        defer self.leave();
        try validate(credential.service, credential.account);
        if (credential.secret.len > sdk.platform.max_credential_secret_bytes) return error.CredentialFieldTooLarge;
        var name: [64]u8 = undefined;
        keyFilename(credential.service, credential.account, &name);
        self.lock();
        defer self.mutex.unlock();
        if (self.locked) return error.CredentialStoreLocked;
        var atomic = try self.dir.createFileAtomic(self.io, &name, .{ .permissions = ownerOnly(), .replace = true });
        defer atomic.deinit(self.io);
        var scratch: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &scratch);
        var writer = atomic.file.writer(self.io, &scratch);
        try writer.interface.writeAll(credential.secret);
        try writer.flush();
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
        try syncDirectory(self);
    }

    fn getCredential(context: ?*anyopaque, key: sdk.platform.CredentialKey, output: []u8) anyerror![]const u8 {
        const self: *Vault = @ptrCast(@alignCast(context orelse return error.CredentialStoreFailed));
        if (!self.enter()) return error.CredentialStoreLocked;
        defer self.leave();
        try validate(key.service, key.account);
        var name: [64]u8 = undefined;
        keyFilename(key.service, key.account, &name);
        self.lock();
        defer self.mutex.unlock();
        if (self.locked) return error.CredentialStoreLocked;
        const file = self.dir.openFile(self.io, &name, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.CredentialNotFound,
            else => return error.CredentialStoreFailed,
        };
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        if (stat.size > output.len or stat.size > sdk.platform.max_credential_secret_bytes) return error.CredentialFieldTooLarge;
        var scratch: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &scratch);
        var reader = file.reader(self.io, &scratch);
        const len: usize = @intCast(stat.size);
        try reader.interface.readSliceAll(output[0..len]);
        _ = reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => return output[0..len],
            else => return error.CredentialStoreFailed,
        };
        std.crypto.secureZero(u8, output[0..len]);
        return error.CredentialFieldTooLarge;
    }

    fn deleteCredential(context: ?*anyopaque, key: sdk.platform.CredentialKey) anyerror!void {
        const self: *Vault = @ptrCast(@alignCast(context orelse return error.CredentialStoreFailed));
        if (!self.enter()) return error.CredentialStoreLocked;
        defer self.leave();
        try validate(key.service, key.account);
        var name: [64]u8 = undefined;
        keyFilename(key.service, key.account, &name);
        self.lock();
        defer self.mutex.unlock();
        if (self.locked) return error.CredentialStoreLocked;
        self.dir.deleteFile(self.io, &name) catch |err| switch (err) {
            error.FileNotFound => return error.CredentialNotFound,
            else => return error.CredentialStoreFailed,
        };
        try syncDirectory(self);
    }

    fn syncDirectory(self: *Vault) !void {
        if (@import("builtin").os.tag == .windows) return;
        const file = try self.dir.openFile(self.io, ".", .{});
        defer file.close(self.io);
        try file.sync(self.io);
    }

    fn lock(self: *Vault) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn noteBlockingCallAbandoned(context: ?*anyopaque) void {
        const self: *Vault = @ptrCast(@alignCast(context orelse return));
        self.lockLifetime();
        self.abandoned = true;
        self.lifetime_mutex.unlock();
    }

    fn enter(self: *Vault) bool {
        self.lockLifetime();
        defer self.lifetime_mutex.unlock();
        if (self.destroy_requested) return false;
        self.active_calls += 1;
        return true;
    }

    fn leave(self: *Vault) void {
        self.lockLifetime();
        self.active_calls -= 1;
        const finalize_now = self.destroy_requested and !self.abandoned and self.active_calls == 0;
        self.lifetime_mutex.unlock();
        if (finalize_now) self.finalize();
    }

    fn lockLifetime(self: *Vault) void {
        while (!self.lifetime_mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn finalize(self: *Vault) void {
        self.lock();
        self.dir.close(self.io);
        self.mutex.unlock();
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }
};

fn validate(service: []const u8, account: []const u8) !void {
    if (service.len == 0 or service.len > sdk.platform.max_credential_service_bytes or
        account.len == 0 or account.len > sdk.platform.max_credential_account_bytes or
        std.mem.indexOfScalar(u8, service, 0) != null or std.mem.indexOfScalar(u8, account, 0) != null or
        !std.unicode.utf8ValidateSlice(service) or !std.unicode.utf8ValidateSlice(account))
        return error.CredentialFieldTooLarge;
}

fn keyFilename(service: []const u8, account: []const u8, output: *[64]u8) void {
    var digest: [32]u8 = undefined;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(service);
    hash.update(&.{0});
    hash.update(account);
    hash.final(&digest);
    const hex = "0123456789abcdef";
    for (digest, 0..) |byte, index| {
        output[index * 2] = hex[byte >> 4];
        output[index * 2 + 1] = hex[byte & 0x0f];
    }
}

fn ownerOnly() std.Io.File.Permissions {
    return if (@import("builtin").os.tag == .windows) .default_file else @enumFromInt(0o600);
}

fn approvedPath(path: []const u8) bool {
    const prefix = "/tmp/subwave-foundation-";
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    const suffix = path[prefix.len..];
    if (suffix.len == 0 or suffix[0] == '/') return false;
    const root_len = std.mem.indexOfScalar(u8, suffix, '/') orelse suffix.len;
    if (root_len == 0) return false;
    var components = std.mem.splitScalar(u8, suffix, '/');
    while (components.next()) |component| if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    return true;
}

fn prepareTestDir(io: std.Io, name: []const u8) ![]const u8 {
    var tmp = try std.Io.Dir.openDirAbsolute(io, "/tmp", .{});
    defer tmp.close(io);
    tmp.deleteTree(io, name) catch {};
    try tmp.createDirPath(io, name);
    return name;
}

fn cleanupTestDir(io: std.Io, name: []const u8) void {
    var tmp = std.Io.Dir.openDirAbsolute(io, "/tmp", .{}) catch return;
    defer tmp.close(io);
    tmp.deleteTree(io, name) catch {};
}

test "synthetic vault persists set get and delete across restart" {
    const name = try prepareTestDir(std.testing.io, "subwave-foundation-automation-vault-unit-persist");
    defer cleanupTestDir(std.testing.io, name);
    const path = "/tmp/subwave-foundation-automation-vault-unit-persist";
    const first = try Vault.init(std.testing.allocator, std.testing.io, path);
    var services = first.services();
    try services.setCredential(.{ .service = "dev.subwave.test", .account = "basic:abc", .secret = "synthetic-secret" });
    first.deinit();

    const second = try Vault.init(std.testing.allocator, std.testing.io, path);
    defer second.deinit();
    services = second.services();
    var output: [sdk.platform.max_credential_secret_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &output);
    try std.testing.expectEqualStrings("synthetic-secret", try services.getCredential(.{ .service = "dev.subwave.test", .account = "basic:abc" }, &output));
    try services.deleteCredential(.{ .service = "dev.subwave.test", .account = "basic:abc" });
    try std.testing.expectError(error.CredentialNotFound, services.getCredential(.{ .service = "dev.subwave.test", .account = "basic:abc" }, &output));
}

test "synthetic vault requires absolute path and exposes locked outcome" {
    try std.testing.expectError(error.UnapprovedAutomationVault, Vault.init(std.testing.allocator, std.testing.io, "relative"));
    const name = try prepareTestDir(std.testing.io, "subwave-foundation-automation-vault-unit-locked");
    defer cleanupTestDir(std.testing.io, name);
    const path = "/tmp/subwave-foundation-automation-vault-unit-locked";
    const value = try Vault.init(std.testing.allocator, std.testing.io, path);
    defer value.deinit();
    value.setLocked(true);
    var services = value.services();
    try std.testing.expectError(error.CredentialStoreLocked, services.setCredential(.{ .service = "dev.subwave.test", .account = "listener:abc", .secret = "x" }));
}

test "synthetic vault rejects symlink root and nested parent escape" {
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    var outside_storage: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const outside_len = try outside.dir.realPath(std.testing.io, &outside_storage);
    const outside_path = outside_storage[0..outside_len];
    var tmp = try std.Io.Dir.openDirAbsolute(std.testing.io, "/tmp", .{});
    defer tmp.close(std.testing.io);

    const root_name = "subwave-foundation-automation-vault-unit-root-link";
    tmp.deleteTree(std.testing.io, root_name) catch {};
    tmp.deleteFile(std.testing.io, root_name) catch {};
    defer tmp.deleteFile(std.testing.io, root_name) catch {};
    try tmp.symLink(std.testing.io, outside_path, root_name, .{ .is_directory = true });
    try std.testing.expectError(error.UnapprovedAutomationVault, Vault.init(std.testing.allocator, std.testing.io, "/tmp/subwave-foundation-automation-vault-unit-root-link"));

    const parent_name = "subwave-foundation-automation-vault-unit-parent";
    tmp.deleteTree(std.testing.io, parent_name) catch {};
    defer tmp.deleteTree(std.testing.io, parent_name) catch {};
    try tmp.createDirPath(std.testing.io, parent_name);
    var parent = try tmp.openDir(std.testing.io, parent_name, .{});
    defer parent.close(std.testing.io);
    try parent.symLink(std.testing.io, outside_path, "escaped", .{ .is_directory = true });
    try std.testing.expectError(error.UnapprovedAutomationVault, Vault.init(std.testing.allocator, std.testing.io, "/tmp/subwave-foundation-automation-vault-unit-parent/escaped"));
}

test "synthetic vault round-trips through the real effects credential worker" {
    const effects = @import("host_effects.zig");
    const vault_mod = @import("credential_vault.zig");
    const name = try prepareTestDir(std.testing.io, "subwave-foundation-automation-vault-unit-effects");
    defer cleanupTestDir(std.testing.io, name);
    const value = try Vault.init(std.testing.allocator, std.testing.io, "/tmp/subwave-foundation-automation-vault-unit-effects");
    var services = value.services();
    var owner = try effects.Owner.init(std.testing.allocator);
    defer owner.deinit();
    owner.effects.bindCredentialsStore(.{ .services = &services, .service = "dev.subwave.player.webviewproof", .permitted = true });

    _ = try owner.vaultGet(1, 1, "basic:empty");
    var miss = try waitVault(&owner);
    try std.testing.expectEqual(vault_mod.Outcome.miss, miss.outcome);
    miss.deinit();
    _ = try owner.vaultSet(2, 1, "basic:test", "synthetic-worker-secret");
    var set = try waitVault(&owner);
    try std.testing.expectEqual(vault_mod.Outcome.ok, set.outcome);
    set.deinit();
    _ = try owner.vaultGet(3, 1, "basic:test");
    var get = try waitVault(&owner);
    try std.testing.expectEqual(vault_mod.Outcome.ok, get.outcome);
    try std.testing.expectEqualStrings("synthetic-worker-secret", get.bytes());
    get.deinit();
    owner.stop();
    value.deinit();
}

test "abandon latch preserves context before a delayed callback enters" {
    const name = try prepareTestDir(std.testing.io, "subwave-foundation-automation-vault-unit-abandon");
    defer cleanupTestDir(std.testing.io, name);
    // Abandonment intentionally retains the tiny synthetic backend until
    // process exit, matching the SDK platform-context lifetime contract.
    const value = try Vault.init(std.heap.page_allocator, std.testing.io, "/tmp/subwave-foundation-automation-vault-unit-abandon");
    const services = value.services();
    services.noteBlockingCallAbandoned();
    value.deinit();
    try std.testing.expectError(error.CredentialStoreLocked, services.setCredential(.{ .service = "dev.subwave.test", .account = "late", .secret = "x" }));
}

fn waitVault(owner: *@import("host_effects.zig").Owner) !@import("host_effects.zig").VaultCompletion {
    for (0..100_000) |_| {
        var boundary = owner.boundary();
        while (owner.next(&boundary)) |raw| {
            var completion = raw;
            completion.deinit();
        }
        if (owner.nextVault()) |completion| return completion;
        std.Thread.yield() catch {};
    }
    return error.TestExpectedVaultCompletion;
}
