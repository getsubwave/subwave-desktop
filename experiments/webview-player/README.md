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

The integrated station foundation is a separate build selection and requires the prepared private SDK copy:

```bash
zig build test-foundation -Dtrace=off \
  -Dnative-sdk-path=../../.superpowers/player-transport-sdk --summary all
zig build -Dfoundation=true -Dtrace=off \
  -Dnative-sdk-path=../../.superpowers/player-transport-sdk \
  --prefix /tmp/subwave-foundation-build
```

Use `-Dfrontend-dev=true` only with the exact loopback Vite origin. Use `-Dautomation=true` only for synthetic automation; it adds `zero://inline` to the bridge policy. Production foundation builds authorize only `zero://app`.

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

Foundation automation can opt into a persistent synthetic vault. The harness must create an existing canonical directory beneath `/tmp/subwave-foundation-*` and export it only to the automation build:

```bash
zig build -Dfoundation=true -Dautomation=true -Dtrace=off \
  -Dnative-sdk-path=../../.superpowers/player-transport-sdk \
  --prefix /tmp/subwave-foundation-automation
python3 ../../scripts/check-player-foundation-linux.py \
  --binary /tmp/subwave-foundation-automation/bin/webview-player-foundation
```

This store contains generated fixture secrets and exists to test restart and transaction behavior. It is distinct from real Keychain, Credential Manager and Secret Service validation. Remove the temporary directory after the run.

## Evidence and scope

See [EVIDENCE.md](EVIDENCE.md) for the measured results and outstanding platform
gates. Native sound output, FFT samples, independent window lifecycle, and
packaged assets require real-host verification. Do not infer them from browser
unit tests. The foundation implements private-station transactions and legacy import in the isolated experiment. Real OS vault acceptance, final platform runtime evidence, visual design, tray, notifications and Discord integration remain separate.

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

The final integrated Linux checker is owned by the repository root:

```bash
python3 ../../scripts/check-player-foundation-linux.py --help
```

Do not treat a successful compile, browser test or synthetic vault test as real native credential or audio proof.

## Linux package

```bash
zig build package -Dpackage-target=linux -Dtrace=off -Dautomation=true -Djs-bridge=true
```

The artifact is `zig-out/package/webview-player-0.1.0-linux-ReleaseFast/`.
Keep its `bin/` and `resources/` directories together. Launch its
`bin/webview-player` with the fixture environment variable above.
This directory package requires the system runtime dependencies; it is not an
installer. Automation flags are for this diagnostic experiment only.
