# SUB/WAVE desktop WebView player design

Date: 2026-09-07

Status: Architecture approved in conversation; written spec ready for review.

## Objective and decisions

Rebuild the desktop interface with React and TypeScript in a Native SDK
WebView, using the SUB/WAVE mobile player's visual language. The user approved
a WebView interface, one mobile-inspired desktop design first, and native-owned
playback. This is a renderer migration, not a conversion to the SDK's compiled
TypeScript plus `.native` authoring path.

Keep a small Zig host where it provides desktop integration. Ship on Linux,
macOS, and Windows. Do not require an installed Node server at runtime. Bundle
the frontend into the application; a station supplies data and media, never the
privileged application interface.

## Current evidence

- The desktop checkout uses `app.zon`, `src/main.zig`, `src/model.zig`, and
  `.native` fragments. The installed CLI reports 0.10.1.
- `src/main.zig` owns window, tray, lifecycle, and Discord helper wiring.
  `src/model.zig` owns playback and polling through UiApp effects. Reusing this
  behavior in a WebView host requires runtime integration work; it is not a
  drop-in view replacement.
- `/home/klair/Projects/subwave/app` is Expo/React Native. Its player uses
  gradients, blur, custom fonts, animated navigation, and a Skia visualizer.
  Use it as the interaction and visual reference, not as desktop source that
  can compile unchanged.
- `/home/klair/Projects/subwave/web/components/player/PlayerCore.tsx` splits
  feed, audio, and actions into contexts. Its audio interface exposes
  `HTMLAudioElement` and the skins consume Web Audio; native playback needs
  a different adapter and visualizer input.
- The web shell includes Next.js, station-auth, theme, and skin assumptions.
  Reuse must audit the dependency closure rather than copy the complete site.
- Installed SDK documentation supports bundled WebViews and custom
  `window.zero.invoke` commands. Its documented limits are 16 KiB requests and
  responses and 12 KiB handler results. Confirm these against the selected
  SDK before implementing the bridge.

## Architecture and ownership

### Bundled frontend

Use React, TypeScript, and Vite in `frontend/`. CSS owns presentation and
animation; use an animation library only where CSS cannot express the required
interaction cleanly. Main and mini-player views use the same application
frontend with separate window routes.

Frontend ownership: navigation, transient forms, dialogs, focus, hover,
responsive layout, motion, and rendering authoritative host state. Separate
metadata updates from playback updates and high-frequency spectrum samples so
the visualizer does not re-render the entire player.

Adapt selected web components and pure types/helpers into this repository.
Record their source revision and license requirements. Do not introduce a
shared package or require changes to the mobile/web repositories for this
first delivery. Remove Next.js/server-only imports from adapted modules.

### Native host

Host ownership: one audio engine, playback/reconnect state, selected station,
station requests and polling, durable preferences, credential storage,
notifications, tray commands, Discord presence, external-link opening, and
window lifecycle. Preserve existing pure Zig modules where useful.

The main window and mini-player send intents to the same host. Closing,
reloading, or hiding an interface must not create a second stream. A newly
opened view obtains a complete state snapshot before applying incremental
updates. The host can continue station polling and notifications while the
main window is hidden.

Use existing platform close semantics: macOS and Windows can hide to a tray;
Linux must retain a reachable interface or quit where no tray is available.
Re-audit the existing close-policy scripts when converting the manifest to
`app.json`; their current ZON text replacement cannot remain unchanged.

### Bridge contract

Define a versioned, typed application contract with runtime validation on the
host. Command families cover playback, station selection/authentication,
listener requests/likes, preferences, window actions, and external links.
Return structured success/error results; never treat acceptance as proof that
playback or a network operation succeeded.

State includes a station generation, increasing revision, playback status,
volume/mute, selected format, metadata, and connection error/retry state.
Discard results from older station generations. Refresh a snapshot after
reconnect or a revision gap. Late command results must not overwrite newer
user choices.

Spectrum samples are bounded numeric arrays delivered separately from durable
state, with sampling/coalescing so a slow view cannot accumulate a queue.
Suspend delivery to invisible views while audio continues. The current SDK
occlusion behavior must be tested when the visible surface is a WebView.

Determine the supported host-to-WebView delivery mechanism in the first
milestone. Native-to-JavaScript push is preferred; a bounded snapshot-polling
adapter is acceptable only after latency and CPU measurements meet the same
interaction goals. Do not assume the invoke request/response API alone provides
subscriptions. Large payloads such as artwork use controlled resource delivery,
not base64 in small bridge responses; lists must be bounded or paginated.

### Station and credential boundary

Make requests in the host to avoid depending on each station's CORS policy.
Bind each request to the currently selected station identity. Allow only the
listener operations the app implements, not arbitrary frontend-supplied
requests or process commands. Validate station addresses, redirects, and
external-link schemes; do not forward credentials across station origins.

Store secrets in the supported OS credential facility. Pass a newly entered
secret to the host once; never return it in snapshots, URLs, logs, or frontend
storage. Preserve existing private-station behavior and test stream
authentication independently from API authentication.

Only the bundled application origin receives privileged bridge access. Open
external content in the system browser. Treat station text as text and
sanitize any intentional rich content. Use a CSP compatible with locally
bundled scripts/fonts and the controlled artwork resource path.

## Desktop experience

Deliver one responsive desktop face inspired by the mobile player: persistent
transport, Shows / Timeline / Live / Booth / Request navigation, expressive
type, cover-derived colour washes, tuner motion, and smooth panels. Preserve
station theme identity while allowing CSS decoration beyond the old native
widget design envelope.

Adapt interactions for pointer and keyboard: visible focus, keyboard transport
that does not intercept text entry, accessible form errors, Escape dismissal,
and deliberate drag regions clear of window buttons. Support reduced motion;
animation must never be necessary to interpret connection or playback state.

The mini-player is a second view of the same playback session. Start with a
compact cover/title/transport layout. Match existing desktop functionality
before adding new skin selection, casting, media-key integrations, or mobile
platform features. Do not promise OS media controls merely because the web
player uses the browser Media Session API.

## Delivery sequence

1. **Runtime proof:** in an isolated checkout, create a bundled WebView host
   and a minimal React control panel. Prove native playback, command round
   trips, state recovery after reload, hidden playback, main/mini synchronization,
   and actual FFT delivery. Inspect the installed SDK source/examples to select
   the host audio and event APIs. Build on all three targets and obtain runtime
   proof on each before declaring the architecture production-ready.
2. **Host and station contract:** extract reusable behavior from the existing
   model, add the validated bridge, generation-safe station access, credential
   handling, preferences, and connection recovery. Use fixture stations and
   deterministic host tests.
3. **Main interface:** adapt reusable web code and build the mobile-inspired
   desktop layout. Verify all five sections, forms, themes, volume, format
   selection, artwork fallback, and motion/accessibility behavior.
4. **Desktop integration:** complete mini-player, tray, notifications, Discord,
   and diagnostics with one authoritative host session. Reconcile background
   lifecycle behavior with each platform.
5. **Migration and release:** import existing settings without losing the old
   file; update SDK pins, patching, manifest tooling, CI, packaging, documentation,
   and release checks. Retire obsolete `.native` views only after parity gates.

Create the detailed implementation plan for the runtime proof first. Use its
measured findings to specify later bridge implementation tasks rather than
invent SDK calls in advance. If host audio cannot operate independently of
UiApp rendering, document the required runtime extraction and its cost before
expanding the rewrite. Do not silently replace native playback with HTML audio.

## Verification and release gates

- Unit/contract tests: invalid commands, wrong origins, stale station results,
  snapshot revision recovery, reconnect decisions, settings import, format
  fallback, and one playback owner across window commands.
- Frontend integration: loading/offline/auth failures, station switch during
  requests, artwork failures, keyboard/forms, reduced motion, and desktop/mini
  layouts. Browser tests use the same typed adapter with a fixture host.
- Actual native runtime: real audible stream, audio events and FFT, pause/mute,
  hiding and reopening, WebView reload during playback, tray commands,
  notifications, Discord, and private-station API plus stream authentication.
- Packaging: bundled assets work without a frontend dev server; credentials
  remain outside assets; installer launch, close behavior, update-check behavior,
  and saved settings work on Linux, macOS, and Windows.
- Measure idle and animated CPU/memory, bridge traffic, dropped/queued samples,
  and interaction latency on the runtime proof; record hardware and an existing
  player baseline. No unbounded queues or background animation. Establish
  numerical regression budgets from those measurements before the visual build.
- Keep `-Dtrace=off` on builds. Reassess the fractional-HiDPI patch against the
  chosen SDK and WebView path; preserve it for retained native surfaces when
  required. Do not delete a workaround solely because the UI language changed.

Focused browser tests do not establish native playback or platform parity.
Report unavailable platform checks explicitly; they remain release gates.

## Migration safety and exclusions

Work in an isolated checkout during implementation and keep the current
release usable until cutover. Preserve application identity and station
preferences, with an explicit settings migration version and backup. Stage
named files; the current untracked `mise.toml` is unrelated user work.

No mobile app migration, full web-site embedding, admin UI, multiple desktop
skins, Electron/Tauri switch, or wholesale removal of Zig is included. The
first release is the approved desktop player experience with a richer renderer.
