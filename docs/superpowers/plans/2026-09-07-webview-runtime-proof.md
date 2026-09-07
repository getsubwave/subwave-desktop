# WebView Runtime Proof Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove one native audio session can be controlled and visualized by two bundled React WebViews without the current `.native` player UI.

**Architecture:** A separate proof app uses the Native SDK system WebView host and platform audio services. A validated command bridge and versioned host snapshots connect a minimal React interface to that session. This milestone measures feasibility; it does not replace the shipping player.

**Tech Stack:** Native SDK 0.10.1 initially, Zig 0.16.0, Node 24, React, TypeScript, Vite, Vitest, Playwright. Lock frontend dependency versions at scaffold time.

**Spec:** `docs/superpowers/specs/2026-09-07-webview-player-design.md`

## Global Constraints

- Ship on Linux, macOS, and Windows.
- Do not require an installed Node server at runtime.
- Bundle the frontend into the application; a station supplies data and media, never the privileged application interface.
- Keep `-Dtrace=off` on builds.
- Do not silently replace native playback with HTML audio.
- No mobile app migration, full web-site embedding, admin UI, multiple desktop skins, Electron/Tauri switch, or wholesale removal of Zig is included.
- This plan implements delivery stage 1 only. The remaining spec stages require follow-on plans informed by this proof.
- Work in an isolated worktree. Use a distinct proof application ID and settings directory; do not read or mutate production preferences.
- Use system WebViews initially. Installed Windows SDK source explicitly reports native audio unsupported by its Chromium backend.
- No public-station listener writes. Use a controlled local stream fixture for repeatable playback and failure tests.

## File map

All implementation files below live under `experiments/webview-player/` in the implementation worktree:

- `app.json`, `build.zig`, `build.zig.zon`, `src/main.zig`, `src/runner.zig`: generated React/WebView scaffold and owned native lifecycle.
- `src/protocol.zig`: request parsing, validation, state serialization, inline tests.
- `src/player_host.zig`: one audio session, revisions, runtime audio events, inline tests.
- `src/view_delivery.zig`: per-window readiness, snapshot delivery and spectrum coalescing, inline tests.
- `frontend/src/bridge.ts`: typed invoke wrapper, snapshot validation, subscription cleanup.
- `frontend/src/bridge.test.ts`: protocol and stale-snapshot tests.
- `frontend/src/App.tsx`: intentionally plain transport, host state and spectrum display; `?view=mini` selects compact presentation.
- `frontend/src/App.test.tsx`: both layouts against a fake bridge.
- `frontend/e2e/player.spec.ts`: browser contract smoke tests using a fake host.
- `frontend/playwright.config.ts`, `frontend/vitest.config.ts`: isolated test setup.
- `fixtures/serve.mjs`: local HTTP stream fixture with connection counters and disconnect control.
- `README.md`: exact run/verification commands and fixture generation.
- `EVIDENCE.md`: SDK seam findings, hardware, measurements and per-platform results.

The generated scaffold is authoritative for build/runner files. If this CLI emits different names, update this map before editing; do not invent a second launcher.

## Task 1: Packaged React window and SDK seam validation

**Deliverable:** A separately identified application loads bundled React assets through a system WebView and answers a native protocol handshake.

**Interfaces:** `subwave.proof.snapshot({})` returns a protocol-1 snapshot. Task 2 defines its complete schema; the initial handshake returns `{ protocol: 1 }` only and must not be used by the full adapter yet.

- [ ] Read the spec and the using-git-worktrees skill; create an isolated branch/worktree with its baseline commit recorded in `EVIDENCE.md`.
- [ ] Run the existing baseline checks once and record failures separately:

```bash
native --version
native check
native test
native build -Dtrace=off
```

- [ ] Inspect current `native init --help`, then scaffold the proof in that worktree:

```bash
native init experiments/webview-player --frontend react
```

- [ ] Set the generated manifest ID to `dev.subwave.player.webviewproof`, title to `SUBWAVE WebView Proof`, and web engine to `system`. Preserve generated asset/dev-server wiring. Grant the bundled origin only the exact proof commands. No remote page gets the bridge.
- [ ] Read `native skills get core --full` and `native skills get automation`. Locate the installed SDK via the resolved CLI path. Trace these actual source seams and record signatures/call order in `EVIDENCE.md`:

```text
src/platform/types.zig: PlatformServices.audioLoadUrl, audioPlay,
  audioPause, audioStop, audioSetVolume, emitWindowEvent, AudioEvent
src/runtime/root.zig: runtime access to platform services and event delivery
src/runtime/ui_app.zig: how existing audio events reach effects
src/platform/null_platform.zig: NullAudio, audio_play_count, takeAudioLoaded,
  advanceAudio, audioSpectrum, failAudio
src/platform/windows/root.zig: supportsFeature system/Chromium differences
```

- [ ] Implement the handshake using the documented `BridgeDispatcher` registration and `bridge.writeJsonStringValue` for dynamic strings. Confirm which JavaScript event surface receives `emitWindowEvent` by inspecting the bundled bridge source. Do not assume DOM event naming.
- [ ] Build packaged assets and the native app, then launch with the frontend dev server stopped. Require a visible React window and successful native handshake. Record actual scaffold build commands and binary location in `README.md`.
- [ ] Commit named proof files. If an SDK seam is absent or needs an upgrade, record the exact failure and proposed change before proceeding; no speculative production SDK upgrade.

## Task 2: Validated session protocol and native audio owner

**Deliverable:** Pure host tests prove one playback owner and explicit command/error semantics, followed by audible playback in the proof window.

**Interfaces:** Implement these exact frontend-facing types in `bridge.ts` and matching validated Zig shapes in `protocol.zig`:

```ts
export type Playback = 'stopped' | 'loading' | 'playing' | 'paused' | 'error';
export interface Snapshot {
  protocol: 1;
  revision: number;
  generation: number;
  playback: Playback;
  volume: number;
  error: string | null;
}
export type Command =
  | { kind: 'play' } | { kind: 'pause' } | { kind: 'stop' }
  | { kind: 'volume'; value: number };
export type Result = { ok: true; snapshot: Snapshot }
  | { ok: false; error: 'invalid_request' | 'unsupported' | 'failed' };
export interface Bridge {
  snapshot(): Promise<Snapshot>;
  command(command: Command): Promise<Result>;
  subscribe(listener: (snapshot: Snapshot) => void): () => void;
}
```

Use `subwave.proof.command` for transport intents. The stream URL comes from the host's `SUBWAVE_PROOF_STREAM_URL` environment variable; the proof frontend cannot submit arbitrary URLs. Restrict proof URLs to the loopback fixture and keep that restriction specific to the experiment.

- [ ] Add failing inline Zig tests for invalid volume (negative, greater than one, nonfinite), malformed/unknown commands, one load across repeated play commands, pause/resume without reloading, and state changes only after real audio events.
- [ ] Add `PlayerHost` in `player_host.zig` with `apply(Command)`, `onAudio(AudioEvent)` and `snapshot()` methods. Store one session and revision; call the verified platform services from Task 1. The load result governs load/play sequencing. Stop/reload must clear old spectrum state.
- [ ] Keep request handling short: no blocking network work inside bridge handlers. If `audioLoadUrl` does blocking work on the selected host, use the SDK's existing asynchronous effect mechanism instead and document its integration. Never add a second runtime to obtain audio effects.
- [ ] Test through NullPlatform counters and injected audio events, including failure after load. Run the generated native test/build commands with trace disabled for builds.
- [ ] Implement `fixtures/serve.mjs` using `node:http`; serve a generated MP3 as a throttled continuous response, track active/total stream connections, and expose loopback-only reset/drop controls. Handle client disconnect cleanup. Document the fixture URL printed on its dynamically allocated port.
- [ ] Generate deterministic test audio with a local tool, for example:

```bash
ffmpeg -f lavfi -i 'sine=frequency=440:sample_rate=44100' -t 30 -c:a libmp3lame fixtures/tone.mp3
```

- [ ] Connect the native proof to the fixture and verify actual audio plus loaded/playing/error events. Kill the fixture connection and require an error or buffering transition, not a permanent false playing state. This proof does not implement the production reconnect policy.
- [ ] Commit the host/protocol/fixture and tests together.

## Task 3: Resilient state and spectrum delivery to React

**Deliverable:** Reloaded and slow views converge on native state without restarting audio or accumulating sample queues.

**Interfaces:** Add `Spectrum = { generation: number; sequence: number; bands: number[] }` and `subscribeSpectrum(listener): () => void` to `Bridge`. Require exactly 32 integer bands in `[0,255]`, matching the installed SDK. Export `acceptSnapshot(current: Snapshot | null, next: unknown): Snapshot | null` from `bridge.ts`; invalid/stale values return the current value.

- [ ] Add failing Vitest tests, including this exact stale-state assertion:

```ts
import { expect, test } from 'vitest';
import { acceptSnapshot, type Snapshot } from './bridge';
test('late snapshots do not rewind playback', () => {
  const current: Snapshot = { protocol: 1, generation: 2, revision: 9,
    playback: 'paused', volume: 0.5, error: null };
  expect(acceptSnapshot(current, { ...current, revision: 8,
    playback: 'playing' })).toBe(current);
});
```

- [ ] Add cases for a previous generation with a larger revision, malformed bands, unsupported protocol, duplicate events, and unsubscribe cleanup. Configure `npm test` to run Vitest and `npm run typecheck` to run `tsc --noEmit` in `frontend/`.
- [ ] Implement validation and invoke wrapping. Subscribe before requesting the initial snapshot, so updates cannot be lost between initialization and event registration. Accept snapshot results through the same generation/revision comparison as pushed state.
- [ ] In `view_delivery.zig`, maintain one latest spectrum sample per view and permit at most one unacknowledged spectrum delivery per view. Add `subwave.proof.spectrumAck({ sequence })`; discard old acknowledgements. New frames overwrite the pending sample. Re-register readiness after a reload and clear old view delivery state.
- [ ] Add a simple React transport panel and a canvas spectrum view. Draw the actual bands without putting each sample in the full React context tree. Display host errors and disable controls before the first valid snapshot. Do not use HTML audio or Web Audio.
- [ ] Test React mount/unmount under StrictMode: no duplicate listeners, commands or loads. Run frontend tests/typecheck and native tests/build.
- [ ] Reload during audible playback, pause from native controls while the view reloads, then reconnect. Require correct paused state and unchanged fixture load count. Artificially delay spectrum acknowledgements for five seconds; pending capacity must remain one.
- [ ] Commit the bridge, view-delivery code and focused tests.

## Task 4: Two windows and background lifecycle

**Deliverable:** Main and mini views control the same session, with sound surviving interface reload/hide and no invisible animation traffic.

**Interfaces:** `subwave.proof.window({ action })` accepts only `openMini`, `closeMini`, `hideMain`, `showMain`. Create/focus an existing mini window instead of duplicating it. Use the SDK window IDs, not untrusted JavaScript IDs, to identify event destinations and readiness.

- [ ] Write native tests for repeated openMini, closeMini while playing, and hidden-view spectrum suspension. Reopening a view must send current snapshot plus the newest sample, not historical samples.
- [ ] Add the second local WebView using the same bundled app with `?view=mini`. Route both command sources into the existing `PlayerHost` instance.
- [ ] Implement visibility/lifecycle handling from the platform's actual window events. Preserve Linux quit behavior for ordinary main-window close; test hiding via the proof controls only while another reachable window exists.
- [ ] Add browser tests in `frontend/e2e/player.spec.ts` using a shared fake host: play from main, pause from mini, volume update reflected in both, listener cleanup after mini closes. Explicitly label this as frontend contract evidence.
- [ ] Repeat with real native windows and the fixture: inspect its active connection count, hide main with mini open, pause/resume in mini, show/reload main, and close mini. Require at most one active stream throughout and no audio restart caused by UI lifecycle alone.
- [ ] Confirm FFT events resume when a WebView is visible. If SDK occlusion gating depends on a native canvas, record a concrete SDK change requirement; a fake spectrum or hidden dummy UI is not a successful proof.
- [ ] Commit window behavior and tests.

## Task 5: Platform evidence and decision

**Deliverable:** A reviewable go/no-go report for the production rebuild, with runnable commands and unresolved platform gates clearly identified.

- [ ] Record SDK commit/version, OS, WebView engine version, CPU, RAM, display scale, stream fixture, and build flags. Repeat runtime verification on Linux, macOS, and Windows using matching hosts. Cross-compilation alone does not pass this gate.
- [ ] In each packaged build, test offline launch of bundled assets, handshake, audible MP3 playback, native FFT, pause/resume, mute via volume zero, reload, main/mini lifecycle, failed stream, and application shutdown with no orphan audio.
- [ ] Measure five minutes each of idle, visible playback with spectrum, and hidden playback. Record CPU, resident memory, sample delivery count, queue capacity, and command-to-state latency. Compare with the old player on the same hardware. Capture frame pacing while visible.
- [ ] Propose numeric regression budgets from the measured baseline in `EVIDENCE.md`; explain any WebView cost and identify the chosen host-to-view delivery mechanism. Do not fill absent measurements with estimates.
- [ ] Verify privilege boundaries: external navigation cannot load into either privileged view; malformed or unregistered commands fail; fixture controls remain loopback-only; packaged assets contain no secrets.
- [ ] Run final native tests/build, frontend tests/typecheck/build, browser tests, and `git diff --check` once after the last changes. Fix relevant failures; record unavailable platform checks as pending.
- [ ] Write one of three conclusions: proceed (all runtime gates passed), proceed with named platform gates still pending (not production-ready), or architecture revision required (with the exact failing seam). Include links to logs/screenshots and commands.
- [ ] Commit the evidence and operator README. Prepare the follow-on implementation plan for host/station migration only after reviewing these findings. Keep the production app intact.

## Plan review

This milestone covers the spec's runtime proof, one session, bridge readiness,
spectrum backpressure, and packaged WebView feasibility. Credentials, full
station polling, settings migration, the designed interface, tray/Discord,
notifications, and production release tooling belong to later stages. They are
not implicitly satisfied by this proof. The runtime result determines whether
the lower-level host or retained SDK effects engine is the viable implementation.
