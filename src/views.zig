//! View registry. The main window dispatches on model.phase (onboarding on
//! first run, the player once tuned); the mini player is a model-declared
//! secondary window.
//!
//! The player is COMPOSED: markup fragments (masthead+dial, sidebar, section
//! panel, transport deck, sheets) around a Zig-built LIVE stage — the stage
//! needs `ui.image` for the square cover art, which markup deliberately
//! excludes (the avatar's circle clip is its only image channel).
//!
//! NOTE: compiling documents this size needs the local SDK fix in
//! ui_markup.zig's canonicalizeComptime (quota raised before the byte-size
//! scan) — see docs/sdk-notes.md.

const std = @import("std");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const model_mod = @import("model.zig");

const Model = model_mod.Model;
const Msg = model_mod.Msg;
const Ui = canvas.Ui(Msg);

const Onboarding = canvas.CompiledMarkupView(Model, Msg, @embedFile("views/onboarding.native"));
const Mini = canvas.CompiledMarkupView(Model, Msg, @embedFile("views/mini.native"));
const PlayerTop = canvas.CompiledMarkupView(Model, Msg, @embedFile("views/player-top.native"));
const PlayerSidebar = canvas.CompiledMarkupView(Model, Msg, @embedFile("views/player-sidebar.native"));
const PlayerPanel = canvas.CompiledMarkupView(Model, Msg, @embedFile("views/player-panel.native"));
const PlayerDeck = canvas.CompiledMarkupView(Model, Msg, @embedFile("views/player-deck.native"));
const PlayerSheets = canvas.CompiledMarkupView(Model, Msg, @embedFile("views/player-sheets.native"));

// Main-window root: setup until a station is tuned, then the player.
pub fn rootView(ui: *Ui, model: *const Model) Ui.Node {
    return switch (model.phase) {
        .onboarding => Onboarding.build(ui, model),
        .player => playerView(ui, model),
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
    mid[n] = stageView(ui, model);
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

// Whole-number comma grouping for the token ticker (markup's thousands()).
fn fmtThousands(arena: std.mem.Allocator, value: i64) []const u8 {
    var digits_buf: [24]u8 = undefined;
    const digits = std.fmt.bufPrint(&digits_buf, "{d}", .{@abs(value)}) catch return "0";
    const groups = (digits.len + 2) / 3;
    const out = arena.alloc(u8, digits.len + (groups - 1) + @intFromBool(value < 0)) catch return digits_buf[0..digits.len];
    var w: usize = 0;
    if (value < 0) {
        out[w] = '-';
        w += 1;
    }
    for (digits, 0..) |ch, i| {
        if (i > 0 and (digits.len - i) % 3 == 0) {
            out[w] = ',';
            w += 1;
        }
        out[w] = ch;
        w += 1;
    }
    return out[0..w];
}

// LIVE stage — text block left, square cover art right (the design's
// record-in-sleeve, square per the latest direction).
fn stageView(ui: *Ui, model: *const Model) Ui.Node {
    const arena = ui.arena;
    const info = arena.alloc(Ui.Node, 9) catch {
        ui.failed = true;
        return ui.column(.{}, .{});
    };
    var n: usize = 0;

    if (model.live_now()) {
        info[n] = ui.row(.{ .gap = 6, .cross = .center }, .{
            ui.appIcon(.{ .width = 14, .height = 14, .style_tokens = .{ .foreground = .accent } }, "radio"),
            ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .accent } }, "ON AIR"),
        });
        n += 1;
    }
    if (model.has_state()) {
        info[n] = ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .accent } }, model.state_line());
        n += 1;
    }

    // "NOW PLAYING — 1:15 / 2:53 · 2,142,144 TOKENS"
    {
        const head = model.np_head(arena);
        const line = if (model.has_tokens())
            std.fmt.allocPrint(arena, "{s} · {s} TOKENS", .{ head, fmtThousands(arena, model.llm_tokens) }) catch head
        else
            head;
        info[n] = ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, line);
        n += 1;
    }

    info[n] = ui.text(.{ .size = .display, .wrap = false }, model.title);
    n += 1;

    // Artist · album · year as one paragraph of styled runs.
    {
        const spans = arena.alloc(canvas.TextSpan, 2) catch {
            ui.failed = true;
            return ui.column(.{}, .{});
        };
        spans[0] = .{ .text = model.artist, .weight = .medium };
        spans[1] = .{ .text = model.album_line(arena), .color = .text_muted };
        info[n] = ui.paragraph(.{}, spans[0..2]);
        n += 1;
    }

    // Like heart (web parity, #991): hidden until the station confirms the
    // airing is likeable, fills only on server confirmation. The whole row is
    // the press target — a 15px glyph alone is a cruel thing to aim at.
    if (model.like_available) {
        info[n] = ui.row(.{
            .gap = 5,
            .cross = .center,
            .on_press = .press_like,
            .semantics = .{ .label = model.like_hint() },
        }, .{
            ui.appIcon(.{
                .width = 15,
                .height = 15,
                .style_tokens = .{ .foreground = if (model.like_liked) .accent else .text_muted },
            }, if (model.like_liked) "heart-fill" else "heart"),
            ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, model.like_count_str(arena)),
        });
        n += 1;
    }

    // "WORLDWIDE · 99 BPM · 11A — ROMANTIC · CALM · LOW ENERGY"
    if (model.has_meta() or model.has_mood()) {
        const meta = model.meta_line(arena);
        const mood = model.mood_line(arena);
        const spans = arena.alloc(canvas.TextSpan, 3) catch {
            ui.failed = true;
            return ui.column(.{}, .{});
        };
        var sn: usize = 0;
        if (meta.len > 0) {
            spans[sn] = .{ .text = meta, .color = .text_muted };
            sn += 1;
        }
        if (mood.len > 0) {
            if (sn > 0) {
                spans[sn] = .{ .text = " — ", .color = .text_muted };
                sn += 1;
            }
            spans[sn] = .{ .text = mood, .color = .accent };
            sn += 1;
        }
        info[n] = ui.paragraph(.{}, spans[0..sn]);
        n += 1;
    }

    if (model.has_booth()) {
        const line = std.fmt.allocPrint(arena, "DJ — {s}", .{model.booth_line}) catch model.booth_line;
        info[n] = ui.text(.{
            .size = .sm,
            .wrap = false,
            .on_press = .open_booth,
            .style_tokens = .{ .foreground = .text_muted },
            .semantics = .{ .label = "Open booth feed" },
        }, line);
        n += 1;
    }

    // Default cross-stretch bounds every text leaf to the column's width, so
    // long titles and DJ lines elide instead of running under the artwork.
    const text_block = ui.column(.{ .gap = 8, .main = .center, .grow = 1, .min_width = 0 }, .{info[0..n]});

    // Record sleeve: field card, SQUARE art (runtime image; initials while
    // the cover loads). Pressing it opens the timeline.
    const art: Ui.Node = if (model.cover_id != 0)
        ui.image(.{ .image = model.cover_id, .width = 180, .height = 180, .semantics = .{ .label = "Cover art" } })
    else
        ui.panel(.{ .width = 180, .height = 180, .style_tokens = .{ .background = .surface_subtle } }, .{
            ui.column(.{ .grow = 1, .main = .center, .cross = .center }, .{
                ui.text(.{ .size = .heading, .style_tokens = .{ .foreground = .text_muted } }, model.initials(arena)),
            }),
        });
    const sleeve = ui.panel(.{
        .padding = 12,
        .on_press = .open_timeline,
        .style_tokens = .{ .background = .surface, .border_color = .border, .radius = .lg },
        .semantics = .{ .label = "Open timeline" },
    }, .{art});

    const stage_row = ui.row(.{ .grow = 1, .gap = 32, .padding = 24, .cross = .center }, .{ sleeve, text_block });

    // Spectrum wave under the stage.
    const series = arena.alloc(canvas.ChartSeries, 1) catch {
        ui.failed = true;
        return ui.column(.{}, .{});
    };
    series[0] = .{ .values = model.bands(), .kind = .bar, .color = .accent };
    const wave = ui.column(.{ .padding = 10 }, .{
        ui.chart(.{ .height = 44, .y_min = 0, .y_max = 1, .semantics = .{ .label = "Spectrum" } }, series),
    });

    return ui.column(.{ .grow = 1, .min_width = 0 }, .{ stage_row, wave });
}
