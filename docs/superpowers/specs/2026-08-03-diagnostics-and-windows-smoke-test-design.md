# Runaway trace log, app diagnostics, and a Windows smoke test that reaches the player

Date: 2026-08-03

Issue #23: the Windows player opens, onboarding works, and then the client area
goes solid white on the way into the player. Audio keeps streaming. The window
stops responding to minimize, maximize and edge-resize, showing the busy
cursor. The reporter is on Windows 11 Pro 26200, single active adapter (RTX
3060 Ti, the onboard Radeon disabled in Device Manager), two monitors both at
100%, and it survived the 0.6.0 → 0.8.0 upgrade unchanged. Their own last
observation was that Bitdefender Antivirus Free appears to be involved.

The investigation on the issue had reached "the message loop is stalled, at
near-zero CPU, so it is blocked on something rather than spinning". This spec
names what it is blocked on.

## Starting position

**The app already writes a log, and nobody knew.** Both sides of the issue
thread believed it did not. `runner.runWithOptions` wires file logging
unconditionally (`app_runner/root.zig:487-500`), keyed on `bundle_id`
(`dev.subwave.player`). On a Linux dev box that is:

```
~/.local/state/dev.subwave.player/logs/native-sdk.jsonl
```

On this machine that file is **423 MB**, twenty days of runtime, never rotated,
no size cap.

**It is dominated by per-frame records.** Sampling the last 20 MB — 162,686
records over 10,430 seconds:

| event | rate |
| --- | --- |
| `audio` | 7.7/s |
| `gpu_surface_frame` | 7.4/s |
| `effects_wake` | 0.3/s |
| everything else | < 0.3/s |

~15.6 records/second sustained. That is a floor, not a ceiling: the FFT feed and
`gpu_surface_frame` are both gated on the window being visibly on screen, so a
foreground session writes faster.

**Each record is a full open/stat/write/close.** `debug.appendFile`
(`debug/root.zig:164-171`):

```zig
var file = try cwd.createFile(io, path, .{ .read = true, .truncate = false });
defer file.close(io);
const stat = try file.stat(io);
try file.writePositionalAll(io, bytes, stat.size);
```

**And it runs on the message loop thread.** `windowsCallback`
(`platform/windows/root.zig:567`) is a `callconv(.c)` callback invoked from the
Windows host's message pump; it calls `RunState.emit` (`:557`), which invokes
the runtime event handler synchronously. The trace write is inline on that
thread, once per frame event, before the pump gets control back.

**It ships on by default.** `-Dtrace` defaults to `.events`
(`build/app.zig:524`), and `shouldTrace` (`app_runner/root.zig:915`) passes
every record named `runtime.event` in that mode. All three release workflows
build with a plain `native build -Dcpu=baseline`. Every binary we have ever
shipped has this on.

### Why this explains #23

Blocking file I/O on the message pump, ~15+ times a second, on a file that only
grows, behind a Bitdefender minifilter that scans on open and close. Every
symptom follows and none contradicts:

- **Stalled loop at near-zero CPU.** Blocked in the filter driver, not spinning.
  That was the fork in the last issue comment, and the reporter's Task Manager
  screenshots land on the blocked branch.
- **Audio survives.** Different thread.
- **Fine during onboarding, blank entering the player.** Onboarding is idle. The
  player starts the frame loop and the audio stream — exactly when
  `gpu_surface_frame` and `audio` records begin firing.
- **"It used to render correctly, and regressed with no system change."** Nothing
  changed on their machine. The log file grew.
- **0.8.0 did not fix it.** The trace sink is unchanged between the two SDKs.
- **The PowerShell `RedrawWindow` workaround paints one frame.** It forces a
  paint through instead of waiting for the queue to drain.

The remaining uncertainty is Bitdefender's exact behaviour on their box, which
we cannot instrument from here. The mechanism above is sufficient on its own and
is what we fix.

### Why the build option cannot be tuned instead

`shouldTrace` filters on `record.name`. Every one of these records is named
`runtime.event`, with the kind (`gpu_surface_frame`, `start`, `audio`) buried in
`fields`. The substring mode therefore cannot separate lifecycle records from
frame records — the only reachable settings are all-runtime-events or nothing.
That forces the shape below: turn the SDK's log off in shipping builds and carry
our own.

## Decisions

1. **Ship with `-Dtrace=off`.** The single change that fixes #23 if the
   diagnosis holds.
2. **Carry our own bounded breadcrumb log** (`src/diag.zig`), so turning the
   SDK's off does not leave users with nothing to send. Held-open handle,
   time-based heartbeat, hard cap, never per-frame.
3. **Make CI able to catch this class of bug** — a Windows smoke test that
   reaches the player phase and asserts the surface actually presented.
4. **Write the real fix up for upstream.** Ours is a workaround; the SDK should
   not do blocking per-frame file I/O on the loop thread.

## Part 1 — Turn the SDK trace log off in shipping builds

Add `-Dtrace=off` to:

- `.github/workflows/release-windows.yml:83` (the shipped build)
- `.github/workflows/release-windows.yml:124` (the automation smoke build)
- `.github/workflows/release-macos.yml:95`
- `.github/workflows/release-linux.yml:92`
- `.github/workflows/ci.yml`'s build step, so CI compiles the shape that ships

Panic capture is outside the trace gate: `installPanicCapture` runs regardless,
and `capturePanic` writes `last-panic.txt` plus its own record directly rather
than through the filtered sink (`debug/root.zig:115-122`, `:197-214`). Crash
reporting survives `-Dtrace=off` intact. `src/main.zig:14` already installs
`native_sdk.debug.capturePanic` as the panic handler, so this keeps working with
no change.

Each of these lines gets a comment explaining why the flag is load-bearing, in
the same register as the existing `-Dcpu=baseline` notes — otherwise a future
edit drops it and silently reintroduces the bug.

### Reclaiming existing users' disk

Shipping the flag stops new growth but leaves every current install carrying the
file. At startup `diag.zig` stats the SDK's `native-sdk.jsonl` and deletes it if
it exceeds 8 MB. One stat on a path we already resolve, a one-time reclaim of up
to hundreds of megabytes, and it keeps machines safe if a future SDK re-enables
tracing by default. Failure at any step is a silent no-op, matching
`settings.zig`'s posture: the app runs without the cleanup rather than not at
all.

## Part 2 — `src/diag.zig`

One module, one job: a bounded breadcrumb log that survives a stalled loop.

### Shape

- Opens once in `main()`, after `settings.resolvePath`, into the SDK's logs
  directory (resolved via `native_sdk.debug.resolveLogPaths`) so everything a
  user needs to send sits in one folder next to `last-panic.txt`.
- **Holds the `std.Io.File` handle for the process lifetime.** This is the whole
  point. No open/close per line.
- Truncates per run; the previous run rolls to `subwave.prev.log`. A hang means
  the user restarts before they think to grab the file.
- Hard byte cap of 256 KB. Past the cap it writes one final `log capped` line
  and goes quiet. The file is evidence, not telemetry.
- Plain text, one line per record, timestamp first. It is meant to be pasted
  into a GitHub issue by someone who is not a programmer.

### What it records

Boot: version, platform, build flags, resolved settings path, resolved station.
Then, over the run: phase transitions; audio start, stop and failure with the
chosen format; stream reconnects and the MP3 fallback; effect failures the model
already tracks.

Plus a **heartbeat every 5 seconds**, driven off the existing `tick_second`
timer (every fifth tick — no new timer, no new effect key). Each heartbeat
carries the current phase, the transport state, and a count of `audio_event`
messages received since the previous one. The model has no frame counter; the
audio event channel is the ~25 Hz animation clock, so that count is the closest
honest proxy for "is the loop still turning", and it separates two failures a
bare timestamp cannot: a dead loop (heartbeats stop) from a live loop with a
dead feed (heartbeats continue, count reads zero).

This is what makes a stall diagnosable rather than merely visible: the log
stops, the last line names the phase, and the gap dates it. It is the single
record that would have answered #23 on day one.

### The two rules in the module header

**Never per-frame, never per-audio-event.** The heartbeat is driven by elapsed
time, not by frame count. Writing a line per frame is the bug this module
exists to fix, not a pattern to copy.

**It writes synchronously, bypassing the effects channel**, against CLAUDE.md's
architecture rule. The header states why: an fx-routed log cannot record the
failure of the loop that runs fx. This exemption is for the diagnostic channel
only and does not extend to anything else in the app.

### Surfacing the path

A back-panel row showing the log folder, so users can find it without being
told where to look. Whether this fits the closed widget vocabulary is unproven
— the back panel's existing rows have not been checked for a
display-a-path-and-let-me-copy-it affordance. Plan item: check first, and drop
the row if it does not fit rather than inventing a widget for it. The
functionality does not depend on it; the path also appears in the log's own
first line and in the issue template.

## Part 3 — A Windows smoke test that reaches the player

The current step (`release-windows.yml:112-139`) launches with no station
configured, so the app parks on onboarding, `native automate wait` reports
ready, and it exits. It never enters the player. It could not have caught this
bug, and it will not catch the next one.

### Reaching the player without a network

Set `SUBWAVE_STATION_URL=http://127.0.0.1:9` — the discard port. `main()` takes
the env override, `api.normalizeBase` accepts it, and `phase` becomes `.player`
with no live station required. Every fetch fails fast; the player chrome
renders, the frame loop runs, and the audio start path executes. That is the
exact transition where #23 goes blank.

Note for the step's comment: the env override persists into `settings.json` on
the machine that runs it. Irrelevant on a fresh runner, dangerous on a dev box.

### What it asserts

```
native automate wait
native automate assert 'gpu_nonblank=true'
native automate assert 'gpu_frame=[1-9]'
native automate screenshot main-canvas
```

`automate snapshot` publishes `gpu_nonblank={any}`, `gpu_sample=0x…` and
`gpu_frame={d}` per gpu_surface view (`automation/snapshot.zig:385`). So:

- Every one of these commands requires the app to service its automation
  channel. A stalled loop fails on timeout instead of passing.
- `gpu_nonblank=true` is the blank-white-client-area assertion, taken from the
  host's own frame sampling rather than a pixel diff — no image tooling on the
  runner.
- `gpu_frame=[1-9]` requires frames to have advanced past zero, catching a
  surface that presented once and froze.

No `|` alternation in those patterns: `native automate assert` does not support
it.

### Where it runs

The fixed step in `release-windows.yml`, and the same step added to `ci.yml`'s
Windows leg so it blocks a merge rather than surfacing mid-release. The other
runners keep doing build-and-test only.

### Risk

The existing step carries an `UNPROVEN` comment about whether automation works
in GitHub's Windows service session; it has only ever exercised `automate wait`.
Adding four commands raises the odds of a flaky red. Mitigations: keep the
documented escape hatch (narrow to launch-and-survive, do not delete), and
upload the screenshot and `subwave.log` as workflow artifacts on failure so a
red run is diagnosable instead of mysterious.

## Part 4 — Upstream

A request document alongside `docs/sdk-audio-device-request.md`, and an entry in
`docs/sdk-notes.md` recording why `-Dtrace=off` is mandatory on every shipping
build. Two asks:

1. `FileTraceSink` should hold its handle open rather than
   open/stat/write/close per record.
2. Per-frame events (`gpu_surface_frame`, `audio`) should not be traced at the
   default level — or `record.name` should carry the event kind so
   `shouldTrace`'s substring mode can filter them.

This stays a workaround on our side until one of those lands.

## Out of scope

- Diagnosing Bitdefender's specific filter behaviour. We cannot instrument the
  reporter's machine, and the fix does not depend on it.
- The `gpu_backend = "metal"` line in the manifest. It is inert on Windows —
  the host hard-codes `.software` (`platform/windows/root.zig:641`) — and
  changing it fixes nothing. Already answered on the issue.
- Log rotation beyond one previous run, log levels, and any form of remote or
  opt-in telemetry.

## Verification

- `native test` and `native check` stay green.
- A local Linux run produces `subwave.log` with boot lines, a phase transition
  and heartbeats, and produces no `native-sdk.jsonl` growth under
  `-Dtrace=off`.
- An oversized `native-sdk.jsonl` is removed on the next launch.
- The new smoke step passes on the Windows CI leg, and fails when pointed at a
  deliberately broken build.
- Ask the reporter on #23 to confirm against a build with `-Dtrace=off`. That is
  the real verification, and it is the one that closes the issue.
