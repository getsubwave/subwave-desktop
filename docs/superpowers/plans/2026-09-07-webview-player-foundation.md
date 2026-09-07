# WebView Player Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add real station selection, native-owned feeds and reconnect, two distinct credential types, and reversible settings import to the proven desktop WebView host.

**Architecture:** React/TypeScript renders sanitized host state and sends typed intents. One Zig host owns station identity, native audio, credential storage, HTTP, timers and persistence. Extend the existing isolated experiment until parity and release gates permit cutover; do not replace the shipping app in this milestone.

**Tech Stack:** Native SDK 0.10.1, Zig 0.16.0, Node 24 for frontend builds/tests only, React/TypeScript/Vite. Native system WebViews; no runtime Node server.

**Spec:** `docs/superpowers/specs/2026-09-07-webview-player-design.md`, delivery stage 2 plus the settings-import portion of stage 5.

## Global constraints

- Ship on Linux, macOS, and Windows.
- Do not require an installed Node server at runtime.
- Bundle the frontend into the application; a station supplies data and media, never the privileged application interface.
- Keep `-Dtrace=off` on builds.
- Do not silently replace native playback with HTML audio.
- Preserve the existing player and its settings until cutover. Tests use temporary configuration, synthetic secrets and fixture stations only.
- Keep the proof application ID `dev.subwave.player.webviewproof` during this milestone. The eventual production identity remains `dev.subwave.player`.
- Work from proof commit `4f93277` in the existing isolated worktree. Stage named files and keep the shipping root source unchanged.
- Parallel Sol agents are the user's chosen execution method. Give independent modules separate owners; integrate dependent host changes sequentially.
- macOS/Windows runtime, OS close/occlusion, frame pacing and comparable ReleaseFast performance remain release gates. Cross-compilation does not close them.

## Evidence that changes the implementation order

Inspected 2026-09-07: desktop `b2ffb98`, WebView proof `4f93277`, mobile reference `/home/klair/Projects/subwave` at `b4790051cfd55fe0e8edc0d2e954d93dd8c9e4aa`.

| Existing source | Reuse or constraint |
| --- | --- |
| Desktop `src/api.zig`, `src/json.zig`, `src/stream_format.zig` | Endpoint/decoder/codec authorities; adapt pure behavior with attribution to this revision, without importing the large old Model. |
| Desktop `src/model.zig:1719`, `src/settings.zig` | Legacy settings schema and startup order; `stationPassword` is currently plaintext in settings. |
| Desktop `src/model.zig:1814` | Reconnect 500 ms doubling to 60 s; Linux optional-format fallback after three failed retries. |
| Mobile `app/src/lib/station-credentials.ts`, `credential-vault.ts`, `station-store.ts` | UTF-8 Basic Auth, credential-free station keys, migration precedence and vault failure semantics. Port invariants, not Expo dependencies. |
| Mobile `app/src/hooks/useStationFeed.ts` | Independent feed failure handling, four-poll offline debounce, and audible-time metadata handling. |
| SDK `src/platform/types.zig:1707,2826,3497` | Audio events lack load identity; URL audio loading accepts no headers. Do not pretend a station generation added at event receipt fixes an old native callback. |
| SDK `src/runtime/credentials_store.zig`, `effects_credentials_tests.zig` | Existing OS vault adapter and asynchronous credential effects. Keys at most 256 bytes, secrets at most 2560 bytes; locked/miss/denied/failure are distinct. |
| SDK `src/runtime/effects.zig:3004,16140` | HTTP effects accept headers but automatically follow bodyless redirects without an app redirect-policy option. Zig HTTP `extra_headers` survive cross-domain redirects. Authenticated requests require explicit redirect control first. |

There are **two separate passwords**: reverse-proxy HTTP Basic username/password, and SUB/WAVE's shared listener password validated by `POST /api/station-auth`. The latter becomes native-only `auth=` stream query data under the existing server contract. Never migrate it into Basic Auth fields or return either secret in snapshots.

## Deliverable boundary and sequence

1. Close the transport prerequisites with fixture evidence.
2. Build station identity, host effects and reconnect against public fixture stations.
3. Add credential storage and private API/audio behavior.
4. Import legacy preferences transactionally into the isolated app.
5. Expose these capabilities through a minimal usable station/player/settings interface.

This milestone does not build the five-section visual redesign, request/like/beacon writes, full artwork rendering, tray, Discord, notifications or release installers. Preserve their preference values during import. Follow-on UI work consumes the interfaces below; it must not move networking or playback into React.

## File map

Paths below are relative to `experiments/webview-player/` unless explicitly called repository paths.

| Files | Responsibility |
| --- | --- |
| `src/transport_contract.zig`, `fixtures/station.mjs`, `fixtures/station.test.mjs` | Transport prerequisite tests and two independently controlled fixture stations. |
| Repository `patches/native-sdk-player-transport.patch`, `scripts/apply-player-transport-patch.sh`, `docs/sdk-player-transport.md` | Reproducible, experiment-scoped SDK extension; never silently mutate the global installed SDK. |
| `src/station_identity.zig`, `src/station_protocol.zig` | Canonical station identity, bounded commands and public DTOs. |
| `src/host_effects.zig`, `src/station_client.zig`, `src/station_decoders.zig` | Bind/drain the SDK effects channel, bounded station request table, decoders. |
| `src/session.zig`, `src/reconnect.zig`, `src/player_host.zig` | User transport intent, active station/load identity, audio state and retry decisions. |
| `src/credential_vault.zig`, `src/preferences.zig`, `src/settings_import.zig` | Host-only credentials and durable nonsecret settings/import transactions. |
| `src/main.zig`, `src/protocol.zig`, `src/view_delivery.zig`, `src/runner.zig`, `app.json`, `build.zig` | Integrate the modules and exact bridge privileges into the proven launcher. |
| `frontend/src/station-bridge.ts`, `StationPanel.tsx`, `PreferencesPanel.tsx`, corresponding tests; `App.tsx` | Presentation of station setup, status, credentials, settings import and transport. |
| `frontend/e2e/station.spec.ts`, `EVIDENCE.md`, `README.md` | Contract smoke tests, actual platform proof and operator commands. |

## Shared contract

`src/station_protocol.zig` and `frontend/src/station-bridge.ts` must implement the same protocol 2. Keep spectrum separate and preserve the proof's per-window ACK/backpressure implementation. Every serialized bridge result must fit the SDK's 12 KiB handler limit; test the fully JSON-escaped maximum snapshot. Canonical station bases are at most 256 bytes, names/theme override at most 64 UTF-8 bytes, track display fields at most 128 UTF-8 bytes. Reject overlong identifiers; shorten display text at a UTF-8 boundary only. Raw decoder bodies and schedules never enter this snapshot.

```ts
export type CredentialEdit =
  | { action: 'keep' }
  | { action: 'clear' }
  | { action: 'replace'; username: string; password: string };
export type Connect = {
  address: string;
  basic: CredentialEdit;
  listenerPassword?: string | null; // input only; omit=retain, null=clear
  allowInsecureHttp: boolean; // explicit user consent, never inferred
};
export type Connection = 'none' | 'checking' | 'ready' | 'offline'
  | 'auth-required' | 'vault-unavailable' | 'error';
export interface OperationStatus {
  operationId: number;
  status: 'pending' | 'succeeded' | 'failed';
  errorCode?: string;
}
export type PreferenceUpdate =
  | { key: 'themeOverride'; value: string }
  | { key: 'discordClientId'; value: string }
  | { key: 'discordEnabled' | 'notifyTrack'; value: boolean };
export type PlaybackCommand =
  | { kind: 'play' | 'pause' | 'stop' }
  | { kind: 'volume'; value: number }
  | { kind: 'mute'; value: boolean }
  | { kind: 'format'; value: 'mp3' | 'aac' | 'opus' | 'flac' };
export interface StationSnapshot {
  protocol: 2;
  revision: number;
  generation: number; // active station activation identity
  playback: 'stopped' | 'loading' | 'playing' | 'paused' | 'error';
  intent: 'stopped' | 'playing' | 'paused';
  buffering: boolean;
  volume: number;
  muted: boolean;
  station: { id: string; base: string; name: string } | null;
  connection: Connection;
  retry: { attempt: number; dueInMs: number } | null;
  track: { id: string; title: string; artist: string; album: string } | null;
  format: 'mp3' | 'aac' | 'opus' | 'flac';
  operations: { station: OperationStatus | null; persistence: OperationStatus | null };
  recents: Array<{ id: string; base: string; name: string }>;
  preferences: {
    themeOverride: string; discordEnabled: boolean;
    discordClientId: string; notifyTrack: boolean;
  };
  error: { code: string; retryable: boolean } | null;
}
export type Accepted = { ok: true; operationId: number }
  | { ok: false; error: 'invalid_request' | 'busy' | 'unsupported' };
```

Commands: `subwave.player.snapshot`, `station.connect(Connect)`, `station.cancel({operationId})`, `station.forget({id})`, `station.disconnect({})`, `playback.command(PlaybackCommand)`, `preferences.update(PreferenceUpdate)`, `preferences.importLegacy({})`; all prefixed `subwave.player.` except the first already-complete name. Use `subwave.player.snapshot` as the event name too. Window and spectrum commands retain their existing proof implementations until renamed together with their callers.

An accepted operation is not success. Report completion through authoritative state plus `subwave.player.operation` carrying `{operationId,status:'succeeded'|'failed',errorCode?:string}`. Snapshot includes a bounded latest-operation status for reload recovery (one station operation and one persistence operation); never include submitted secrets. Only one station mutation may run at once; cancellation invalidates its operation identity. Playback commands remain available during candidate probing.

## Task 1: Prove and implement the missing transport contracts

**Files:** `src/transport_contract.zig`, fixture station files and repository SDK patch/script/document above; `build.zig` test imports.

**Produces:** a pinned, verified native transport with per-load event identity, authenticated URL loading and no credential-bearing redirects. This is a prerequisite, not a feature claimed by SDK 0.10.1 today.

- [ ] Extend the controlled fixture with `/api/health`, `/api/state`, `/api/now-playing`, `/api/session`, `/api/themes`, `/api/schedule`, `/api/station-auth` and paced MP3. Add Basic-auth and listener-password modes, configurable response delays/failures and redirects to a second fixture origin. Logs retain authorization-present booleans only, not header/query values. Bind literal loopback by default.
- [ ] Add HTTP tests that independently prove API auth, stream auth, station listener-password auth, delay/drop controls and redirect destination counters. Keep the existing stream fixture tests.
- [ ] Make a private SDK working copy selected through the generated build's `-Dnative-sdk-path`; preserve the installed SDK and existing fractional-scale patch. Record SDK commit and patch order. The application patch script must assert its target path/version and support an idempotent check mode.
- [ ] Implement these **proposed SDK extension contracts**, preserving the old APIs for the shipping app:

```zig
// Proposed additions; absent from SDK 0.10.1.
pub const AudioUrlRequest = struct {
    load_id: u64,
    url: []const u8,
    headers: []const std.http.Header = &.{},
    allow_redirects: bool = false,
};
// PlatformServices.audioLoadRequest(AudioUrlRequest) -> !AudioLoadResolution
// AudioEvent gains load_id: u64 = 0 (legacy callers use zero).
// Effects.FetchOptions gains follow_redirects: bool = true;
// the station client always supplies false.
```

Capture `load_id` at source/callback creation, including native callbacks, queued runtime events, FFT, failures and completion; do not stamp the currently active ID when draining. Reject unsupported authenticated loads explicitly. Never put Basic credentials in URL userinfo as a fallback. Disable redirects for credential-bearing stream loads; prove backend behavior rather than trusting a flag name.

- [ ] First failing native scenario: start load 41, replace it with 42, deliver 41's loaded/failed/spectrum/position events; no 42 state, play counter or visualizer change is permitted. Require events from 42 to work normally. Exercise each backend's actual callback path as well as NullPlatform.
- [ ] First failing HTTP scenario: authenticated GET to fixture A redirects to fixture B; B must receive zero requests. Host reports `redirect_denied`. Direct authenticated GET to A succeeds. Test HTTPS-to-HTTP redirects and POST redirects too.
- [ ] Prove credential-free native stream URL plus explicit UTF-8 Basic header on each system backend using synthetic credentials. A backend without a supported implementation remains `unsupported`; do not enable private-station playback there or mark Task 1 complete. If this requires a larger SDK transport redesign, record the exact failing backend/API and revise this prerequisite before dependent private-station work.
- [ ] Run native tests and fixture tests, then Linux/macOS/Windows builds with trace off. Capture real-host authenticated PCM and stale-load behavior where hosts exist; unavailable hosts stay open gates. Commit only the patch, tests, reproducible script and seam evidence, never a copied SDK tree.

## Task 2: Station identity and an asynchronous host request owner

**Files:** identity/protocol/client/decoder/effects modules and their inline tests; `src/main.zig`, `app.json`.

**Interfaces:** `normalizeStation(raw, output) -> !StationIdentity`; identity stores canonical credential-free base and SHA-256-derived stable ID. `RequestTag {operation_id:u64, generation:u64, request_id:u64, kind:Endpoint}` accompanies every queued response. `Endpoint` is the closed enum `health, now_playing, state, themes, session, schedule, station_auth`; no arbitrary URL/method bridge.

- [ ] Add normalization cases for bare host, hostname case, default ports, IPv6, trailing slash, optional base path, invalid scheme, control characters and oversized input. Trim input, default to HTTPS, lowercase DNS host, remove default port and trailing slash; reject query/fragment, backslash and URL userinfo in new input. Only the migration parser may extract legacy userinfo. Preserve a normalized nonempty base path, rejecting dot segments and encoded path separators.

```text
" RADIO.EXAMPLE:443/ " -> "https://radio.example"
"http://[::1]:43127/" -> "http://[::1]:43127"
"https://radio.example/player/" -> "https://radio.example/player"
"https://u:p@radio.example" -> invalid new input
"javascript:alert(1)" -> invalid
```

- [ ] Bind a single `Effects(Msg)` to the WebView host using `bindServices`, `bindEnviron`, `bindCredentialsStore` and constrained file access, following SDK `ui_app.zig:1504`. Drain with `drainBoundary`/`takeMsgWithin` at runtime event boundaries; copy borrowed completion data before the next drain. Use bounded request slots and monotonically unique keys. No blocking fetch or keyring call in bridge handlers.
- [ ] Use SDK `fetch` with `follow_redirects=false`, 8-second timeout, bounded bodies, and host-built paths. A redirect yields `redirect_denied`; instruct the user to enter the final station address. Do not probe HTTP after a bare HTTPS address fails. Explicit HTTP requires consent before sending either kind of secret.
- [ ] Probe `/api/health` before selecting a candidate. A candidate operation reads/validates credentials before replacing the active station. Failure or cancellation leaves current audio and selected station untouched. If two connects race, reject the second as `busy` until cancel/completion; a canceled candidate cannot later activate.
- [ ] Port bounded decoders from desktop `src/json.zig`, preserving missing/null/unknown-field behavior. Cap input bodies at 256 KiB, decoded track strings at 512 UTF-8 bytes each (project display text to the smaller bridge limits), themes at 32, schedule entries at 64 and recents at eight. Reject over-bound input explicitly, not by truncating an identity or credential.
- [ ] Test late A health/feed results after B activation, malformed JSON, timeout, independent endpoint failure and rapid cancel/connect. Test that credential bytes, Authorization and native stream URLs are absent from all DTOs. Run native tests and commit this owner before adding retries.

## Task 3: One station session, polling and reconnect

**Files:** `src/session.zig`, `src/reconnect.zig`, `src/player_host.zig`, client integration and inline tests.

**Interfaces:** `Session.apply(Intent)` produces host work; `Session.onResponse(RequestTag, response)` and `Session.onAudio(load_id, event)` mutate only matching identities. Station activation increments `generation`; every replacement/reconnect allocates a new `load_id`. A timer also carries generation, load ID and timer ID.

- [ ] Separate user intent from engine state. Pause/stop/disconnect cancel retries and buffering watchdogs immediately. Pause during load must cancel/unload it; a later loaded event cannot start playback. A healthy pause/resume keeps the same stream; recovery after failure starts a new load.
- [ ] On candidate success: cancel old polling and pending operations; invalidate old generation/load; stop old audio; clear station metadata/privacy/format state; install candidate and credentials; load its preference (MP3 default); start exactly one audio load and feed set. Views never own a session.
- [ ] Poll now-playing/state/session independently every 5 seconds; themes/schedule every 30 seconds. Keep at most one request per endpoint, skip overlapping ticks and cancel on switch. Hidden desktop views do not change station ownership. Defer likes, requests and beacon writes to the later product-actions task.
- [ ] Implement deterministic backoff and manual retry cancellation:

```text
failure attempts 1..9: 500,1000,2000,4000,8000,16000,32000,60000,60000 ms
pause/stop before timer: no new audio load
old timer after station switch: no new audio load
Linux failed optional format at attempt 3: select/persist MP3, then retry
```

Reset failures after confirmed healthy playback, not bridge acceptance. Preserve four consecutive `streamOnline:false` polls before confirmed station-offline teardown; a true poll resets that counter. Reconnect only while intent is playing. Add a 6-second buffering watchdog as an explicitly tested policy, without importing Android-specific churn workarounds.

- [ ] Use `src/stream_format.zig` as the desktop codec authority, intersected with station-advertised flags. MP3 is the floor. Preferences belong to each station; import the old global format into the active imported station only. Unsupported user selections fail without changing the saved preference.
- [ ] Keep actual native FFT and bounded delivery. Clear frames on load identity change; retain the newest sample so a paused/reloaded view can initialize. Suspend hidden-view traffic. Suppress duplicate unchanged snapshots on position ticks.
- [ ] Test loaded/failed/FFT from old load, stale timers, pause during load, repeated Play, offline debounce, fallback and switch during every in-flight endpoint. Run fixture playback/drop/retry with main and mini open: stream count changes only for intended replacement/reconnect. Commit with those tests.

## Task 4: Host-only credential vault and private stations

**Files:** `src/credential_vault.zig`, client/session integration, `app.json`, credential tests.

**Interfaces:** vault operations carry operation ID and canonical station ID; separate account keys `basic:<sha256(base)>` and `listener:<sha256(base)>`. Outcomes preserve `ok, miss, locked, denied, io_failed, over_bound, rejected`. Basic entry serializes username/password only inside the vault; listener entry stores the shared listener password separately.

- [ ] Enable SDK credentials capability and permission in the isolated manifest/runner, bind the app namespace, and test through the SDK hermetic credential backing. Never expose builtin credential-get commands to React.
- [ ] Port mobile test invariants: UTF-8 Basic encoding; clean identity; `keep` versus `clear` versus `replace`; existing vault data wins during import; read failure is not a miss. Bound the complete serialized secret to 2560 bytes and key to 256 bytes. Clear sensitive transient buffers after use.
- [ ] Fetch candidate credentials before disturbing current playback. Newly entered credentials travel once from the form to the host and never return in results. Confirm a replacement against the candidate, then persist; a failed write leaves the old session and stored credentials usable. Locked vault offers retry; it does not erase a record or silently downgrade to public access.
- [ ] Apply Basic headers to every same-origin station API and the native audio request through Task 1's transport. Validate shared password with `/api/station-auth`; only after success append percent-encoded `auth=` inside the native stream request. For future station-gated controller reads, use `x-station-auth` separately from proxy Authorization; current server authority is `controller/src/util/listener-auth.ts`. Treat 401, 403, 429 and network failure distinctly. Never automatically erase a saved credential because the network failed.
- [ ] Serialize vault mutations per station/key, including cancellation and replacement. A canceled operation may not activate a station or let a late older write overwrite a newer credential; wait for its terminal vault outcome before accepting another mutation on that key. Test cancel during get/set/delete and subsequent replacement.
- [ ] Test fixtures for public, Basic-only, listener-password-only and combined auth. Add consent tests for explicit HTTP, no bare-host HTTP downgrade, percent-encoded listener tokens, Unicode Basic credentials, rejected login and vault-unavailable retry.
- [ ] Use sentinel synthetic secrets to scan snapshots, bridge replies, settings, logs, journals and frontend dist. New secrets may exist only in input transient memory, vault storage and the authorized transport. The preserved legacy source/backup in Task 5 is the explicit compatibility exception for already-existing plaintext credentials; it must never become the new app's settings store. Keep real-secret tests out of file-based CLI automation. Commit after both API and native stream authentication are verified; API-only success is insufficient.

## Task 5: Transactional preferences and legacy import

**Files:** `src/preferences.zig`, `src/settings_import.zig`, session integration and fixture tests.

**Produces:** version-2 JSON under SDK `app_dirs` name `subwave-player-next`, filename `settings.v2.json`. Resolve the legacy path through name `subwave-player` plus `settings.json`, matching `src/settings.zig`. No automatic production-file reads during development verification. At cold start, load version-2 preferences before opening the player; a configured `SUBWAVE_STATION_URL` override wins for the session only and must not overwrite saved station identity.

```json
{
  "version": 2,
  "volume": 0.8,
  "themeOverride": "",
  "activeStationId": null,
  "stations": [],
  "discordEnabled": false,
  "discordClientId": "",
  "notifyTrack": false,
  "legacyImport": {"completed": false, "sourceDigest": null}
}
```

Each station record is `{id,base,name,streamFormat,allowInsecureHttp}`. No passwords, Authorization, credentialed URLs or `auth=` values. Mute is session-only. Preserve Discord/notification/theme values even though their integrations are later milestones.

- [ ] Encode/decode with bounded owned storage, eight MRU stations, default volume .8 clamped 0..1, MP3 default, notifications/Discord off, empty theme override and no active station. Validate Discord client ID using existing desktop behavior. Ignore obsolete `skin`; preserve all documented current preferences.
- [ ] Write a same-directory temporary file with owner-only permissions, flush, atomically rename and flush the parent directory where supported. Serialize saves; debounce volume by 800 ms and persist a dirty latest revision after an in-flight save. A failure reports persistence error and retains the last good file.
- [ ] Import only through `preferences.importLegacy` using the host-resolved path; the frontend cannot submit file paths. Read at most 8192 bytes. Missing file is a distinct no-import result; malformed/oversized input is a visible error and must not trigger a default overwrite.
- [ ] Build an import candidate in memory. Extract URL userinfo into Basic credentials; interpret `stationPassword` only as the active station's listener password. Normalize/dedupe active and recents, retaining MRU cap eight; active legacy credentials win over recent candidates, but existing secure credentials win over all legacy candidates.
- [ ] Transaction order: preserve one owner-only backup of the source, read existing vault entries, write only absent entries, verify those writes, then atomically commit sanitized version-2 preferences plus the source digest/import marker. The original file remains untouched. Never write the marker before credentials and preferences succeed. Repeating after a crash must neither overwrite existing credentials nor duplicate recents.
- [ ] Keep migration output unchanged on vault error. On restart without a valid completed version-2 file, offer retry; do not silently declare import complete. Test crashes after each write boundary, corrupt files, failed rename, permission denial and vault lock. All these tests use temporary synthetic files.
- [ ] Forget uses a durable nonsecret pending-removal record, removes both vault keys, then commits the recent-list removal; retry reconciliation on restart if interrupted. A visible deletion failure keeps the recent listed with retry status. Forgetting the active recent does not stop the active in-memory session; Disconnect clears active state and stops audio while keeping other recents.
- [ ] Test cold start with imported station/settings, idempotent second import, global-format-to-active-station mapping, legacy unknown fields and stored empty values. Commit after the original fixture file remains byte-identical across success/failure/retry.

## Task 6: Usable frontend and integration acceptance

**Files:** frontend station/preferences panels and adapter/tests, existing App, native dispatcher/security and README/EVIDENCE.

- [ ] Add the protocol-2 adapter with runtime validation, subscribe-before-snapshot, monotonic generation/revision acceptance and bounded latest-operation recovery. Preserve existing spectrum cleanup and mini synchronization.
- [ ] Render a station URL form, optional Basic username/password fields, a separate station-listener-password prompt, explicit HTTP consent, saved station list, retry/cancel/error states, metadata text and format/volume controls. Clear secret form fields after submission. Disable repeat submission while the corresponding mutation is pending; keep current playback controls usable during probing.
- [ ] Add import/retry status and retained preference controls. An import failure must never look like an empty successful migration. Use native-owned operation results for completion; avoid optimistic selected-station or saved-credential success.
- [ ] Restrict production privilege to `zero://app`; enable exact Vite origin only in development and `zero://inline` only for synthetic automation builds. Deny external navigation in both views. Declare CSP for bundled scripts/styles; station text renders as text. Show artwork fallback in this milestone rather than credentialed remote image URLs.
- [ ] Add browser tests with a fake host for failed candidate preserving A, successful B activation, vault retry, operation recovery after reload, cancel versus late result, HTTP consent and both window controls. Label them contract evidence.
- [ ] Run native/fixture/frontend/typecheck/browser/build/manifest checks using README commands. Run real packaged Linux tests outside the checkout with temporary settings: public and private station switch, API plus audio auth, drop/reconnect, old-load rejection, reload/mini/hide, import/restart and cleanup. Record unavailable macOS/Windows tests as open gates.
- [ ] Update EVIDENCE with source/SDK patch identity, concrete test counts and limitations. Review code and evidence independently. Commit named files; keep shipping cutover, credentials migration of real user data and full visual redesign outside this milestone.

## Acceptance and execution handoff

The foundation is complete only when Tasks 1–6 have their required evidence. SDK authenticated-stream or callback-identity failure is an explicit prerequisite failure; do not relabel it as successful private-station support. The shipping app remains usable throughout.

Execution order: Task 1 first. After its transport contract is verified, station identity/client and pure preferences/import tests can run with separate Sol owners. Integrate session and vault dependent changes sequentially, then attach the frontend. Use a fresh reviewer for credential/redirect/migration boundaries and one final integrated review.

Remaining release work: macOS/Windows runtime parity, comparable performance budgets and frame pacing, complete mobile-inspired interface including audible metadata timing/artwork, listener writes, desktop integrations and final application-identity/settings cutover. None is implicitly satisfied by this foundation plan.
