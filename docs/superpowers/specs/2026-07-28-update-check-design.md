# Update check + notify (self-update Phase 1)

Approved direction (2026-07-28): the app checks GitHub Releases for a newer
version, shows a quiet in-app notice, and opens the release page in the
default browser on click. No binary download or replacement — that is a
possible later phase and explicitly out of scope here.

## Why this shape

- The Native SDK has no built-in updater. Its effects channel caps buffered
  fetch bodies at 256 KiB and `writeFile` at 1 MiB, so artifact downloads are
  out of reach of the effects channel by design — full self-update would need
  a helper process. Phase 1 needs none of that.
- Releases live on the public `getsubwave/subwave-desktop` repo. The
  unauthenticated `GET /repos/getsubwave/subwave-desktop/releases/latest`
  endpoint returns `tag_name` for the newest published release (drafts and
  prereleases excluded), well within the 60 req/hr anonymous rate limit at a
  daily cadence.
- `close_policy = hide` on macOS/Windows means the app can stay resident for
  weeks, so a launch-time check alone is not enough — a repeating timer
  carries the cadence.

## Components

**`src/update.zig`** — new pure module with inline tests, following the
api.zig/stream_format.zig pattern:

- `pub const version = "0.5.0";` — the compiled-in app version. `app.zon`
  cannot be imported from `src/` (outside the module path), so this constant
  is the runtime authority and `scripts/make-release.sh` gains a preflight
  assert that it matches `app.zon` before a release can be cut.
- `pub const release_api_url` / `pub const release_page_url` — the GitHub
  endpoints above. The click-through opens the static
  `…/releases/latest` page rather than a stored per-release URL, so no URL
  buffer lives on the Model.
- `pub fn isNewer(tag: []const u8) bool` — strips an optional leading `v`,
  parses `MAJOR.MINOR.PATCH` strictly (any non-numeric component → `false`),
  numeric-compares against `version`. Equal or older → `false`.
- `pub const opener_argv` — comptime per-OS argv prefix for opening a URL:
  `open` (macOS), `xdg-open` (Linux), `cmd /C start "" <url>` (Windows).

**`src/json.zig`** — `pub const Release = struct { tag_name: ?[]const u8 = null };`
decoded with the existing `ignore_unknown_fields` parse.

**`src/model.zig`**:

- Keys: `fetch_update = 43`, `update_timer = 44`, `open_release_spawn = 45`.
- Model fields: `update_tag_buf: [24]u8` + `update_tag: []const u8 = ""`
  (empty = no update known; the tag doubles as the availability flag), and
  `opener_inflight: bool` so a double-click cannot reuse a still-active
  spawn key.
- View helpers: `update_available()`, `update_value()` (tag for display),
  `app_version()`.
- Msgs: `got_update`, `tick_update`, `opener_exited` (all `view_unbound`),
  and `open_release` (markup-bound).
- `boot`: schedule the first check immediately and start a repeating 24 h
  timer — in both phases, since the check is station-independent.
- Fetch: explicit `User-Agent` and `Accept: application/vnd.github+json`
  headers (GitHub rejects UA-less requests; the SDK sets no default),
  10 s timeout.
- `.got_update`: only `outcome == .ok and status == 200` bodies are parsed;
  `tag_name` passes `isNewer` → copied into `update_tag_buf`, else the tag
  is cleared. Every failure mode (offline, rate-limited, truncated body,
  junk JSON) is silent — the next daily tick retries.
- `.open_release`: guard on `opener_inflight`, then `fx.spawn` the platform
  opener with `on_exit = .opener_exited` clearing the guard.

**Views** (inside the design envelope — station tokens only, closed widget
vocabulary, `download` is in the built-in icon set):

- `player-sheets.native`, BACK PANEL sheet: a conditional `SERVICE` section
  between INTEGRATIONS and SHORTCUTS — a row with the `download` icon,
  "Update available", the new tag in accent on the right, chevron;
  `on-press="open_release"`. The footer line gains the current version:
  `MODEL SW-D1 · V{app_version} · MADE FOR THE INTERNET`.
- `player-top.native`: a 10 px `circle-dot` in accent next to the settings
  button while an update is known — the discoverability nudge.

**`scripts/make-release.sh`** — preflight assert `src/update.zig` version
equals `app.zon` version (same fail-hard style as the existing checks).

## Testing

- `update.zig` inline tests: `isNewer` across newer/equal/older on each
  component, missing `v`, junk, prerelease-suffixed tags (strict parse →
  `false`).
- `model.zig` reducer tests (existing fake-executor pattern): a 200
  `got_update` with a newer tag sets `update_tag`; an older tag clears it;
  `open_release` schedules the opener spawn (`pendingSpawnAt`) and the
  inflight guard swallows a second click until `opener_exited`.
- `json.zig`: `Release` decode test.
- `src/tests.zig`: rebuild the top fragment and the `.panel` sheet with
  `update_tag` set so the conditional row and dot go through build+layout.

## Out of scope

Binary download/replacement, checksums in CI, macOS notarization, and any
Windows/Linux install-dir writability logic — all Phase 2 concerns.
