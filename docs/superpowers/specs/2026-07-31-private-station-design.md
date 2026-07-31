# Private-station support (station password)

2026-07-31 · mirrors the SUB/WAVE web player's privacy feature (#478 in the
subwave monorepo).

## What the station exposes

Authority: `controller/src/routes/public.ts` + `controller/src/util/listener-auth.ts`
in `~/Projects/subwave`; web reference `web/components/player/StationGate.tsx` +
`web/lib/stationAuth.ts`.

- `/api/state` carries `privacy: { privatePlayer, listenerAuth }` — booleans
  only, never the password. Old stations omit the object (→ both false). The
  desktop app already polls `/api/state` every 5 s.
  - `privatePlayer` — the whole player UI is members-only.
  - `listenerAuth` — the Icecast stream itself requires credentials.
  - One shared station password backs both locks.
- `POST /api/station-auth` body `{"password": "…"}` → 200 `{ok:true}` on match,
  401 on mismatch, 429 when rate-limited (20 attempts / 15 min / IP). Fails
  CLOSED whenever either lock is on. This is the ONLY validation endpoint the
  player may use — `/listener-auth` fails open when stream auth is off.
- Stream mounts accept the password as an `?auth=<pw>` query param (browsers
  can't attach basic auth to an audio element; the desktop app uses the same
  mechanism). Icecast forwards the mount incl. query to the controller.
- All other public endpoints (`/api/now-playing`, `/api/health`, `/api/dj`, …)
  stay unauthenticated server-side; privacy is a client-side gate plus stream
  auth, exactly as on the web.

## Design

A lock screen (new `views/lock.native`) REPLACES the player whenever a privacy
lock is engaged and no validated password is on hand. The web overlays the
player for listenerAuth-only stations and only fully replaces it for
privatePlayer; the desktop uses one full gate for both — simpler (no
non-dismissible special case in the sheet system) and errs on the private side.

State machine on the Model (mirrors the web's checking/prompt/ok phases):

    auth_gate: enum { idle, checking, prompt, ok }   // .idle = no lock seen
    station_locked() = (privacy_private or privacy_listener_auth)
                       and auth_gate != .ok

Transitions, driven by the existing `/api/state` poll (`got_state`):

- flags on + `.idle`: stored password → POST `/station-auth` (`.checking`);
  none stored → `.prompt`, tune out, close the mini player, close any sheet.
- flags off (operator unlocked mid-session): back to `.idle`.
- `got_station_auth` 200 → store the candidate as `station_pw`, persist,
  `.ok`, clear the input, tune in (stream URL now carries `?auth=`).
- 401 with a stored candidate → clear it, `.prompt` silently (rotation).
- 401 with a typed candidate → `.prompt` + "That password was not accepted."
- 429 → "Too many attempts — wait a few minutes and try again."
- network error → "Couldn't reach the station." (stays `.prompt`; the next
  submit retries).

Stream auth: `startStream` appends `auth=<percent-encoded pw>` to the mount URL
whenever a password is stored — same unconditional ride-along as the web's
`withStreamAuth` (harmless when stream auth is off; the query is ignored).

Persistence: `stationPassword` joins settings.json (plaintext — parity with the
web player's localStorage token). It is cleared when the listener switches
stations: unlike per-origin browser storage, one settings file serves every
station, and the old station's password must never be POSTed to a new one.

While locked: feed/theme timers keep running (`/api/state` is how the client
learns the lock flipped, and the data is public server-side either way), but
nothing renders except the gate, audio is stopped, and transport/mini/like
messages are ignored in `update`.

## Components

- `api.zig` — `stationAuth()` URL builder; `withStreamAuth(buf, url, token)`
  percent-encoding appender (+ tests).
- `json.zig` — `Privacy` on `StationState`; `stationPassword` on `Settings`.
- `model.zig` — fields (`privacy_private`, `privacy_listener_auth`,
  `auth_gate`, `station_pw` + buf, `pw_buffer` input, `auth_body_buf`,
  `auth_try` + buf, `auth_from_store`, `auth_status`), `keys.post_station_auth`,
  Msgs `pw_edit` / `submit_pw` / `got_station_auth`, reducer wiring, guards,
  settings round-trip, station-switch clearing (+ unit tests).
- `views/lock.native` + `views.zig` dispatch + `tests.zig` layout coverage.

## Known limitations

- The Native SDK has no masked/password text field, so the password shows as
  typed. Acceptable: it's a shared listener secret, not a personal credential.
- Mid-session password rotation while `.ok` isn't re-checked until the stream
  fails or the app restarts (web behaves the same — it validates at mount).
- The password is stored per-app, not per-station; switching stations forgets
  it by design.
