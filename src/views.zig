//! View registry. The main window dispatches on model.phase (onboarding on
//! first run, the player once tuned); the mini player is a model-declared
//! secondary window. All views are comptime-compiled markup — binding
//! mistakes are build errors.

const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const model_mod = @import("model.zig");

const Model = model_mod.Model;
const Msg = model_mod.Msg;
const Ui = canvas.Ui(Msg);

const Player = canvas.CompiledMarkupView(Model, Msg, @embedFile("views/player.native"));
const Onboarding = canvas.CompiledMarkupView(Model, Msg, @embedFile("views/onboarding.native"));
const Mini = canvas.CompiledMarkupView(Model, Msg, @embedFile("views/mini.native"));

// Main-window root: setup until a station is tuned, then the player.
//
// NOTE: compiling a document the size of player.native needs the local SDK
// fix in ui_markup.zig's canonicalizeComptime (quota raised before the
// byte-size scan) — see docs/sdk-notes.md.
pub fn rootView(ui: *Ui, model: *const Model) Ui.Node {
    return switch (model.phase) {
        .onboarding => Onboarding.build(ui, model),
        .player => Player.build(ui, model),
    };
}

// Declared-window views ("mini" is the only label windows_fn emits).
pub fn windowView(ui: *Ui, model: *const Model, window_label: []const u8) Ui.Node {
    _ = window_label;
    return Mini.build(ui, model);
}
