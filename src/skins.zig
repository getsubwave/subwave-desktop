//! App-skin registry. A skin is a self-contained layout (its own .native
//! markup) over the shared Model; the runtime re-selects on every rebuild, so
//! flipping model.skin reskins the whole window with zero other changes. Both
//! skins bind the same fields and are repainted by the same station theme
//! (theme.tokensFn) — only layout + material density differ.

const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const model_mod = @import("model.zig");

const Model = model_mod.Model;
const Msg = model_mod.Msg;
const Ui = canvas.Ui(Msg);

// Comptime-compiled markup views — binding mistakes are build errors.
const Card = canvas.CompiledMarkupView(Model, Msg, @embedFile("skins/card.native"));
const Deck = canvas.CompiledMarkupView(Model, Msg, @embedFile("skins/deck.native"));

// Root view: dispatch to the active skin's compiled tree.
pub fn rootView(ui: *Ui, model: *const Model) Ui.Node {
    return switch (model.skin) {
        .card => Card.build(ui, model),
        .deck => Deck.build(ui, model),
    };
}
