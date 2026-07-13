//! Durable player settings — volume, skin, theme override, station — persisted
//! as settings.json in the OS per-app config dir. The path is resolved in
//! main() (needs the env map + app_dirs), the file is read synchronously at
//! startup so the skin/station are known before the window opens, and saved
//! asynchronously via fx.writeFile on change (see model.saveSettings).

const std = @import("std");
const native_sdk = @import("native_sdk");
const model_mod = @import("model.zig");
const Model = model_mod.Model;

// Resolve <config>/subwave-player/settings.json into the model's buffers.
pub fn resolvePath(model: *Model, env_map: *std.process.Environ.Map) void {
    const dirs = native_sdk.app_dirs;
    const platform = dirs.currentPlatform();
    const env = native_sdk.debug.envFromMap(env_map);
    var dir_buf: [640]u8 = undefined;
    const dir = dirs.resolveOne(.{ .name = "subwave-player" }, platform, env, .config, &dir_buf) catch return;
    const path = dirs.join(platform, &model.settings_path_buf, &.{ dir, "settings.json" }) catch return;
    model.settings_path = path;
}

// Read + apply settings.json synchronously (startup). Missing file / parse
// failure is a silent no-op — the defaults stand. cwd().readFileAlloc opens an
// absolute sub_path directly.
pub fn loadFromDisk(model: *Model, io: std.Io) void {
    if (model.settings_path.len == 0) return;
    const alloc = std.heap.page_allocator;
    const cwd = std.Io.Dir.cwd();
    const bytes = cwd.readFileAlloc(io, model.settings_path, alloc, .limited(8192)) catch return;
    defer alloc.free(bytes);
    model_mod.applySettingsJson(model, bytes);
}
