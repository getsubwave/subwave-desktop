# Brief for Claude Design — SUB/WAVE desktop (Native SDK constraints)

The four screens (Desktop Player, Onboarding, Tray Popover, Mini Player) were
implemented in the **Native SDK** — a native desktop toolkit that renders every
pixel through its own **closed widget vocabulary** driven by **theme tokens**.
It is not a browser: there is no HTML/CSS, no arbitrary styling, no free-form
drawing. Several parts of the current design lean on CSS features that cannot
be reproduced, so the build adapted them. Please update the design project so
the mockups live inside the envelope below — then the desktop app can match
them ~1:1.

## Hard constraints (design inside these)

**Color** — every color must be one of the 7 station theme tokens:
`bg`, `ink`, `muted`, `accent`, `field` (surface), `soft-border`, `overlay`.
No per-element hex values, no `color-mix()`, no alpha layering tricks, no
gradients of any kind (linear/conic/repeating). One accent per theme.

**Typography** — one bundled sans face plus a monospace channel. Sizes are a
fixed scale: small (~12), body (~14), heading (28), display (48). No custom
fonts (Fraunces / JetBrains Mono / Plus Jakarta Sans can't load), no
letter-spacing control, no arbitrary px sizes, no text-transform (uppercase
must be authored as uppercase text). Bold / medium / italic / mono / underline
are available as inline spans.

**No CSS decoration** — unavailable: repeating tick patterns (FM dial ruler,
knurled knob edge, dot-grid mute button), conic-gradient vinyl disc, box
shadows, custom border radii per element, blur, absolute positioning,
`-webkit-line-clamp`, custom scrollbars.

**No animation** — no keyframes at all: no spinning disc, no ripple rings, no
scan sweep, no pulsing live dot, no blinking cursor, no needle transition.
The only motion primitives are a stock spinner (loading) and a live bar chart.
Nothing meaningful can depend on motion.

**Widget vocabulary** (roughly): rows/columns/cards, buttons (default /
outline / ghost / primary), toggle-button chips + tab strips, list rows,
text field / search field / textarea, slider (horizontal), progress bar,
badge (small filled pill), separator, avatar (CIRCULAR image clip), bar/line
charts, a closed set of ~50 stroke icons (plus app-registered single-color
stroke SVGs), modal surfaces: dialog, bottom SHEET, drawer. Anchored dropdown
menus exist for pickers; free-floating positioned popovers do not.

**Windows/OS** — macOS traffic lights replace custom –/▢/× buttons (hidden
titlebar + the masthead as drag region). The tray is a NATIVE MENU (text rows,
separators, disabled lines) — a custom-drawn popover panel is impossible.
No always-on-top for the mini window. One fixed layout per window (no
responsive breakpoints); windows have min sizes instead.

## What was adapted in the current build (and what to redesign)

1. **FM dial band** → became a centered strip of 5 small toggle-chips
   (SHWS · TML · LIVE · BTH · REQ). Redesign the dial as a chip/tab strip —
   no ruler ticks, no animated needle. An accent-filled active chip is the
   "needle".
2. **Cover art** → the SDK clips images to a CIRCLE (avatar). Build shows a
   square bordered "sleeve" card with a round disc inside — a record-in-sleeve
   look. Either embrace that in the design, or accept the circle; corner
   crop-marks/ripples/scan overlays are gone.
3. **Rotary volume knob** → horizontal slider + percent readout + mute
   toggle-button (single `volume` icon; no speaker-x variant exists).
4. **Signal meter** → label ("SIGNAL · GOOD — 23 listening · 84 ms") + a plain
   progress bar. No tick ruler, no glowing grip.
5. **Back panel popover** (anchored top-right card) → a bottom SHEET with
   scrim. Sleep timer and Theme sub-views are sheets too. Design these as
   bottom sheets. OUTPUT section (System/Cast) was dropped — no cast support.
6. **Stations sidebar** → a modal drawer over the player, not an inline
   280px column. (An inline column IS possible if preferred — say which.)
7. **Theme cards with 3-color swatches** → arbitrary per-card colors are
   impossible; themes render as list rows (name + check). If swatches matter,
   the design should expect exactly one accent-dot per row at most.
8. **Tray popover** → the rich panel became a native text menu:
   track · artist (disabled), Tune in/out, Play/Pause, Mute, Sleep timer,
   Mini player, and the app title "S/W ♪" as the live indicator. Design the
   tray as a MENU (ordered text rows), not a panel.
9. **Keyboard glyphs** — ⌘, ⌄, ▸, ♪, ◈, ⤢, ▍, ↳, ∞ are outside the bundled
   font (render as tofu). Use words ("Cmd K", "Space", "Esc") or plain
   ASCII. `·`, `—`, `…`, `°`, `–` are safe.
10. **Blinking DJ-line cursor, listener-count "♪" glyph, swripple/swscan/
    swspin/swblink** — all dropped; design the equivalent static treatments.
11. **Custom window buttons** — replaced by macOS traffic lights; the design
    should show a 52px-tall masthead with ~76px of left clearance for them.

## What matched well (keep these patterns)

- Overall structure: masthead / dial band / stage / right 380px section
  panel / transport deck strip.
- The waveform as a bar chart (accent-on-ink) — natively supported, animates
  with real FFT data.
- Editorial type hierarchy (display title, small muted labels, accent
  moments) — reproduces well within the token scale.
- LINE OPEN request slip card, booth feed rows with VOICE/PICK/TRACK badges,
  UP NEXT numbered rows, schedule ranges — all map cleanly to list rows,
  badges, and cards.
- The four theme palettes — they arrive at runtime as station theme tokens
  and repaint everything.

## Requested deliverable

Updated `Desktop Player.dc.html`, `Onboarding.dc.html`, `Mini Player.dc.html`
using ONLY: the 7 tokens, system-ish sans + mono, the widget vocabulary above,
no animation-bearing meaning, bottom sheets for the back panel / sleep /
themes, and a menu-shaped tray spec (a simple ordered list is enough — it
renders as a native menu). Keep the 980×660 main window (min 880×560), 420×168
mini, and a single fixed layout per window.
