# Native WebView playback proof

An isolated experiment for the approved React desktop rebuild. The shipping
player at the repository root is unchanged. This interface is a diagnostic
control panel, not the planned visual redesign.

## Prerequisites

Use the repository's Node 24 and Zig 0.16.0 toolchain, Native SDK 0.10.1, and a
working desktop session. Linux needs the SDK's GTK/WebKitGTK and GStreamer
runtime dependencies. Use the system WebView backend for this proof. Run all
commands below from this directory unless stated otherwise.

## Build

```bash
npm --prefix frontend ci
npm --prefix frontend run build
zig build -Dtrace=off -Dautomation=true -Djs-bridge=true
```

The scaffold also exposes `-Dnative-sdk-path=/absolute/path/to/sdk` for a
locally installed SDK. Run `zig build --help` for the complete build surface.
The frontend is built into `frontend/dist`; no dev server is needed to launch
from this directory.

## Local audio fixture

Follow [fixtures/README.md](fixtures/README.md) (its commands start at the repository root) to generate the MP3 tone and
start the loopback stream server. Use the exact URL it prints:

```bash
SUBWAVE_PROOF_STREAM_URL=http://127.0.0.1:PORT/stream.mp3 ./zig-out/bin/webview-player
```

Replace `PORT` with the fixture's actual port. The host only accepts a local
fixture stream in this experiment. It does not connect to production station
accounts or read production player preferences.

## Automation

Run these commands in another terminal with this directory as its working
directory:

```bash
native automate wait
native automate snapshot
native automate bridge '{"id":"snapshot","command":"subwave.proof.snapshot","payload":{}}'
native automate bridge '{"id":"play","command":"subwave.proof.command","payload":{"kind":"play"}}'
native automate bridge '{"id":"pause","command":"subwave.proof.command","payload":{"kind":"pause"}}'
native automate bridge '{"id":"mini","command":"subwave.proof.window","payload":{"action":"openMini"}}'
native automate reload
```

Native automation inspects windows and invokes host commands. It does not
capture WebView pixels or test React DOM interactions. Frontend browser tests
use a fake host and establish frontend contract behavior only.

## Evidence and scope

See [EVIDENCE.md](EVIDENCE.md) for the measured results and outstanding platform
gates. Native sound output, FFT samples, independent window lifecycle, and
packaged assets require real-host verification. Do not infer them from browser
unit tests. Production authentication, station migration, visual design, tray,
notifications and Discord integration are subsequent milestones.

## Checks

```bash
zig build test -Dtrace=off --summary all
node --test fixtures/serve.test.mjs
npm --prefix frontend test
npm --prefix frontend run typecheck
npm --prefix frontend run test:e2e
npm --prefix frontend run build
native validate app.json
```

## Linux package

```bash
zig build package -Dpackage-target=linux -Dtrace=off -Dautomation=true -Djs-bridge=true
```

The artifact is `zig-out/package/webview-player-0.1.0-linux-ReleaseFast/`.
Keep its `bin/` and `resources/` directories together. Launch its
`bin/webview-player` with the fixture environment variable above.
This directory package requires the system runtime dependencies; it is not an
installer. Automation flags are for this diagnostic experiment only.
