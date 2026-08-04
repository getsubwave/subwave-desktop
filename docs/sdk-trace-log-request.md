# SDK request: the file trace sink blocks the message loop

## What happens

`runWithOptions` wires `debug.FileTraceSink` unconditionally
(`app_runner/root.zig:487-500`). With the default `-Dtrace=events`
(`build/app.zig:524`), `shouldTrace` (`app_runner/root.zig:915`) passes every
record named `runtime.event` — which includes `gpu_surface_frame` and `audio`,
emitted once per rendered frame and per audio callback.

`debug.appendFile` (`debug/root.zig:164-171`) does a full open, stat, write,
close per record:

    var file = try cwd.createFile(io, path, .{ .read = true, .truncate = false });
    defer file.close(io);
    const stat = try file.stat(io);
    try file.writePositionalAll(io, bytes, stat.size);

And it runs on the platform message loop thread: `windowsCallback`
(`platform/windows/root.zig:567`) is a `callconv(.c)` callback from the host's
pump, calling `RunState.emit` (`:557`), which invokes the runtime event handler
synchronously.

## Measured impact

On a Linux dev box running the SUB/WAVE player:
`~/.local/state/dev.subwave.player/logs/native-sdk.jsonl` reached **423 MB**
over twenty days with no rotation and no size cap. Sampling the last 20 MB —
162,686 records over 10,430 seconds, ~15.6/s sustained:

| event | rate |
| --- | --- |
| `audio` | 7.7/s |
| `gpu_surface_frame` | 7.4/s |
| `effects_wake` | 0.3/s |
| everything else | < 0.3/s |

That is a floor, not a ceiling — both high-rate events are gated on the window
being visibly on screen.

On Windows behind Bitdefender's real-time minifilter, which scans on open and
close, this stalls the message pump. Symptoms: solid white client area, busy
cursor on minimize/maximize/edge-resize, near-zero CPU (blocked, not
spinning), audio unaffected because it runs on its own thread. It worsens as
the file grows, so it presents as a regression with no system change. Reported
as getsubwave/subwave-desktop#23.

## Asks

1. **`FileTraceSink` should hold its handle open** rather than
   open/stat/write/close per record. This alone removes the per-frame
   syscall storm and the AV scan trigger.
2. **Per-frame events should not be traced at the default level.** Today
   `-Dtrace` cannot express this: `shouldTrace` filters on `record.name`, and
   every one of these records is named `runtime.event` with the kind in
   `fields`. Either exclude high-rate events from `.events`, or put the event
   kind in `record.name` so the substring mode can filter them.
3. **Bound the file.** Rotation or a size cap; today it grows forever.

## Our workaround

Every shipping build passes `-Dtrace=off`, guarded by
`scripts/check-release-flags.sh`. The app carries its own bounded breadcrumb
log (`src/diag.zig`) instead. Panic capture is unaffected —
`installPanicCapture` runs outside the trace gate.
