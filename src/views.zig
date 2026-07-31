//! View registry. The main window dispatches on model.phase (onboarding on
//! first run, the player once tuned); the mini player is a model-declared
//! secondary window.
//!
//! The player is COMPOSED entirely from markup fragments: masthead+dial,
//! sidebar, LIVE stage, section panel, transport deck, sheets. The stage used
//! to be hand-built Zig because it needs a square runtime image for the cover
//! art and markup had no `image` leaf; SDK 0.6.0 added one, so this file is now
//! just composition — which conditional fragments appear, in what order.

const std = @import("std");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const model_mod = @import("model.zig");

const Model = model_mod.Model;
const Msg = model_mod.Msg;
const Ui = canvas.Ui(Msg);

const Onboarding = canvas.CompiledMarkupView(Model, Msg, @embedFile("views/onboarding.native"));
const Lock = canvas.CompiledMarkupView(Model, Msg, @embedFile("views/lock.native"));
const Mini = canvas.CompiledMarkupView(Model, Msg, @embedFile("views/mini.native"));
const PlayerTop = canvas.CompiledMarkupView(Model, Msg, @embedFile("views/player-top.native"));
const PlayerSidebar = canvas.CompiledMarkupView(Model, Msg, @embedFile("views/player-sidebar.native"));
const PlayerStage = canvas.CompiledMarkupView(Model, Msg, @embedFile("views/player-stage.native"));
const PlayerPanel = canvas.CompiledMarkupView(Model, Msg, @embedFile("views/player-panel.native"));
const PlayerDeck = canvas.CompiledMarkupView(Model, Msg, @embedFile("views/player-deck.native"));
const PlayerSheets = canvas.CompiledMarkupView(Model, Msg, @embedFile("views/player-sheets.native"));

// Main-window root: setup until a station is tuned, then the player — unless
// a privacy lock is engaged without a validated password, in which case the
// gate replaces the player outright (mirrors web StationGate's privatePlayer
// mode; one full gate covers listenerAuth too — see docs/superpowers/specs/
// 2026-07-31-private-station-design.md).
pub fn rootView(ui: *Ui, model: *const Model) Ui.Node {
    return switch (model.phase) {
        .onboarding => Onboarding.build(ui, model),
        .player => if (model.station_locked()) Lock.build(ui, model) else playerView(ui, model),
    };
}

// Declared-window views ("mini" is the only label windows_fn emits).
pub fn windowView(ui: *Ui, model: *const Model, window_label: []const u8) Ui.Node {
    _ = window_label;
    return Mini.build(ui, model);
}

// ------------------------------------------------------------ player compose
fn playerView(ui: *Ui, model: *const Model) Ui.Node {
    // Middle row: [sidebar] · stage · [panel] — conditional set in an arena
    // slice (fragment roots carry their own separators).
    const mid = ui.arena.alloc(Ui.Node, 3) catch {
        ui.failed = true;
        return ui.column(.{}, .{});
    };
    var n: usize = 0;
    if (model.sidebar_open) {
        mid[n] = PlayerSidebar.build(ui, model);
        n += 1;
    }
    mid[n] = PlayerStage.build(ui, model);
    n += 1;
    if (model.panel_open()) {
        mid[n] = PlayerPanel.build(ui, model);
        n += 1;
    }
    return ui.column(.{ .grow = 1 }, .{
        PlayerTop.build(ui, model),
        ui.row(.{ .grow = 1 }, .{mid[0..n]}),
        PlayerDeck.build(ui, model),
        PlayerSheets.build(ui, model),
    });
}
