# Discord Rich Presence: client ID configurable from the UI

2026-08-01 · approved approach: carry the client ID inside the existing helper stdin payload.

## Problem

The Discord Rich Presence client ID is baked in at build time via `src/discord.zon`,
and the checked-in placeholder is empty — so every released build shows
"Not configured" and users would have to rebuild the app to use the feature.

## Goal

Any user of a released build can create a Discord application at
discord.com/developers, paste its Application ID into the Discord sheet, and have
Rich Presence work — no rebuild. The build-time `discord.zon` ID remains as an
optional default (a fork can still ship one).

## Design

### Delivery: the ID rides the existing stdin payload

`discord_rpc.ActivityRequest` gains `client_id`. The model sends the *effective*
ID (user-entered if set, else the build-time one) in the request JSON piped to
the `--discord-rpc-helper` child; the helper handshakes with `req.client_id`
(falling back to the comptime constant if the field is empty, for safety).
Because the ID is part of `buildActivityRequestJson` output, it lands in the
respawn signature automatically — editing the ID live tears the helper down and
reconnects under the new identity.

### Model state (src/model.zig)

- `discord_id_buffer: canvas.TextBuffer(24)` — the sheet's input field (TEA style,
  like `station_buffer`).
- `discord_client_id_buf: [24]u8` / `discord_client_id: []const u8` — the saved,
  validated ID (persisted).
- `discord_id_status: []const u8` — static literal shown under the field
  ("" = nothing; set on invalid input).
- `discord_error: []const u8` — static literal mapped from helper ERROR lines.
- `discord_configured` becomes a **getter** (was a bool field):
  `effectiveDiscordClientId().len > 0`. Markup bindings are unchanged.

New Msgs (all markup-bound): `discord_id_edit: canvas.TextInputEvent`,
`submit_discord_id`, `clear_discord_id`.

`submit_discord_id`: trim → validate (17–20 ASCII digits, `discord_rpc.isValidClientId`)
→ on failure set `discord_id_status`; on success store the ID, clear the field
and status, **auto-enable** the feature (the only reason to paste an ID is to
turn it on), save settings, and refresh the presence.

`clear_discord_id`: drop the saved ID (and the presence with it, unless a
build-time default exists), save settings.

### Helper feedback (src/main.zig)

The handshake-response read gains an opcode check: Discord answers an invalid
client ID with an opcode-2 close frame rather than the opcode-1 READY dispatch —
today that would sail through as "accepted". Non-1 opcode → `ERROR: client id rejected`.
Empty effective ID → `ERROR: no client id` (belt-and-braces; the model never
spawns unconfigured).

The model's `.discord_line` arm maps ERROR lines to friendly literals surfaced
through `discord_status_line`:

- `ERROR: Discord not running` → "Discord isn't running"
- `ERROR: client id rejected` → "Discord rejected the client ID"
- any other `ERROR: …` → "Connection to Discord failed"
- otherwise (enabled, no error yet) → "Waiting for Discord…"; READY → "Connected"
  (READY also clears the stored error).

### Persistence (src/json.zig + settings save/apply)

`Settings` gains `discordClientId: ?[]const u8`. Saved alongside
`discordEnabled`; applied on boot with the same validation as the UI path (a
hand-edited invalid ID is ignored).

### UI (src/views/player-sheets.native, Discord sheet)

- The on/off toggle row + status line show when `discord_configured` (as today).
- Below it, an always-visible CLIENT ID block: an `<input>` bound to
  `{discord_id_text}` with on-input/on-submit, a Save button, an error line when
  `has_discord_id_status`, and — when a user ID is saved — the ID with a Clear
  button. Help copy points at discord.com/developers. Stays inside the design
  envelope (station tokens, fixed type scale, existing widget vocabulary).

### Tests

- `discord_rpc.zig`: `isValidClientId` cases; request JSON includes `client_id`;
  the worst-case-size test keeps covering the new field.
- `model.zig`: submit valid/invalid, clear, settings round-trip, ERROR-line →
  status mapping, ID-change-forces-respawn.
- `tests.zig`: layout coverage for the new sheet branches; sets the client-ID
  field instead of the removed `discord_configured` bool.

## Out of scope

- No live "Test" button (status line already reports the outcome).
- No masking/secret handling — client IDs are public identifiers.
- No per-station IDs.
