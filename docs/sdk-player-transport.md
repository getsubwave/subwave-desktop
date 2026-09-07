# Private player transport extension

This work supports the isolated WebView player foundation. It does not upgrade
or patch the globally installed Native SDK, and it does not replace the
shipping desktop app. Baseline: Native SDK 0.10.1 with the existing fractional
HiDPI patch applied.

## Contracts

- `PlatformServices.audioLoadRequest`: explicit native load ID and checked
  request options. System backends support empty headers with redirects allowed;
  other policies return `UnsupportedService` before changing playback. The
  relay owns remote request headers and redirect denial. The legacy
  `audioLoadUrl` API remains available.
- `AudioEvent.load_id`: captured from the source that produced the event,
  preserved through native callbacks and queued runtime delivery.
- `Effects.FetchOptions.follow_redirects`: station HTTP can reject redirects
  before credentials reach a different destination.
- `audio_relay.zig`: native host-owned upstream request, bounded streaming and
  an unguessable loopback capability URL for the existing native decoder.
  No JavaScript server or browser audio is involved.

macOS and Windows stock URL loaders do not provide the complete authenticated
request plus redirect-denial contract. Their new request method must reject
unsupported options explicitly. The shared relay owns that upstream policy;
native decoding consumes a local URL from a server that never redirects.
Linux uses the same relay and strict request policy, so all remote
credentials and redirect decisions have one transport owner.

The relay prototype must be verified before production station code depends on
it. MP3 is the initial live fixture. Platform codec/range behavior, macOS ATS,
Windows runtime and all shutdown cases are explicit gates, not consequences of
a successful cross-build.

The resulting ownership is:

```mermaid
flowchart LR
    UI[React controls] --> Host[Zig session]
    Host --> Relay[Native loopback relay]
    Relay -->|Authenticated HTTP, no redirects| Station[Station]
    Decoder[Native audio decoder] -->|Private local URL| Relay
    Decoder -->|PCM and FFT| Host
    Host -->|Sanitized state and FFT| UI
```

The relay is the first prototype because Apple's supported alternative is a
full resource loader, while Microsoft's network sources do not support the
simple byte-stream replacement initially considered. Sources:
[Apple resource loader](https://developer.apple.com/documentation/avfoundation/avassetresourceloaderdelegate),
[Microsoft network source features](https://learn.microsoft.com/en-us/windows/win32/medfound/network-source-features).

## Private SDK preparation

Run from the repository root:

```bash
./scripts/apply-player-transport-patch.sh \
  --sdk-path .superpowers/player-transport-sdk \
  --prepare-from "$(npm root -g)/@native-sdk/cli"
./scripts/apply-player-transport-patch.sh \
  --sdk-path .superpowers/player-transport-sdk --check
```

The source SDK must already contain the existing fractional-HiDPI patch. The
installer checks the SDK version and exact before/after file hashes. It refuses
an existing preparation target, unmarked SDK, changed baseline or symlinked
patch destination. A failed application rolls back touched source files.
A clean private copy fails `--check` until the transport patch is applied.
If preparation fails after copying, the private directory remains available
for inspection; correct the cause and retry without `--prepare-from`.

## Fixture-only native probe

Start the fixture in another terminal (synthetic credentials only):

```bash
cd experiments/webview-player/fixtures
./generate-tone.sh
FIXTURE_BASIC_USERNAME=fixture-user FIXTURE_BASIC_PASSWORD=fixture-pass \
  node station.mjs --auth-mode basic
```

Use the printed primary port below. The probe rejects non-literal-loopback
addresses and exits after eight seconds by default. It logs event IDs and
sample counts, never URL/header values.

```bash
cd experiments/webview-player
zig build -Dtrace=off -Dtransport-probe=true \
  -Dnative-sdk-path=../../.superpowers/player-transport-sdk
SUBWAVE_TRANSPORT_URL=http://127.0.0.1:PORT/stream.mp3 \
SUBWAVE_TRANSPORT_AUTHORIZATION='Basic Zml4dHVyZS11c2VyOmZpeHR1cmUtcGFzcw==' \
./zig-out/bin/transport-probe
```

Set `SUBWAVE_TRANSPORT_REPLACE_URL` to a second fixture URL to replace native
load 41 with 42 during startup. Native callbacks from 41 must stay identified
as 41 and be ignored by the probe's current-load gate. All platforms use
the relay for authenticated remote requests.

The probe is intentionally separate from `webview-player`; normal builds and
its existing protocol-1 frontend still use the established proof entrypoint.

## Checks

```bash
python3 scripts/tests/player-transport-patch.test.py
cd experiments/webview-player
node --test fixtures/serve.test.mjs fixtures/station.test.mjs
zig build test -Dtrace=off -Dtransport-probe=true \
  -Dnative-sdk-path=../../.superpowers/player-transport-sdk
zig build test -Dtrace=off
cd ../..
python3 scripts/check-player-transport-linux.py \
  --binary experiments/webview-player/zig-out/bin/transport-probe
```

The Linux runtime check requires a desktop session, FFmpeg and `pactl`. It
starts two loopback fixture origins with synthetic Unicode credentials, uses
a private null audio sink, verifies PCM/FFT, redirect refusal and replacement,
and cleans up its processes, sink and temporary settings on exit. It routes
only the probe process to that sink.

## Verified evidence — 2026-09-07

All final native checks used the SDK reconstructed by the committed patch
installer, rather than the development SDK working copy. Baseline SDK 0.10.1;
existing fractional-HiDPI patch precedes this extension. Zig 0.16.0, Node 24.19.0.

| Check | Result |
| --- | --- |
| Private SDK platform suite | 246 passed, 2 skipped |
| Private SDK runtime-core suite | 683 passed, 12 skipped |
| Native transport/relay tests | 12 passed |
| Existing WebView native proof | 13 passed |
| HTTP fixture suites | 14 passed |
| Installer tests | 6 passed |
| Actual Linux C callback harness | Passed; stale load 41 callbacks leave load 42 state unchanged and emit no events |
| Linux transport executable | Built with trace off |
| Windows transport executable including relay | Cross-compiled and linked with trace off |

The repeatable Linux runtime check passed all three scenarios:

- Unicode Basic authentication reached the upstream fixture. Native MP3 decoding
  produced PCM at **-26.4 dBFS mean** plus FFT events.
- A redirect response produced a failed native load and **zero destination
  requests**. The relay's upstream client does not follow redirects.
- Immediate replacement 41 → 42 produced loaded/FFT events for 42, with no
  accepted 41 event after replacement. This proves live replacement; the C
  harness separately injects stale callbacks.

Every scenario finished with zero upstream active streams. The checker scanned
its temporary logs, cache and config artifacts for synthetic credential bytes,
then removed its fixture processes, private Pulse sink and temporary settings.
The real SDK HTTP-worker tests separately cover authenticated GET and
body-bearing POST returning a cross-origin 307 without contacting its target.

Reproduce the C callback check from the repository root:

```bash
experiments/webview-player/tests/run-linux-audio-callbacks.sh
```

The SDK suites are intentionally focused: the copied SDK omits tooling/eval
inputs needed by its full suite, and this host has unrelated full-suite linker
constraints. Skipped platform tests do not establish macOS/Windows runtime
behavior.

## Remaining gates

This is experimental transport groundwork, not enabled private-station support
in the shipping player. macOS Objective-C compilation and real macOS/Windows
playback, callback replacement, ATS, codec/range behavior and shutdown remain
open. The Windows cross-build is compile/link evidence only. HTTPS certificate
and HTTPS-to-HTTP redirect cases also need dedicated fixture coverage.

The relay supports one admitted progressive GET per load with bounded buffers;
HEAD, byte ranges, seek and decoder reconnects are not implemented. Complete
invalid requests are rejected without consuming the capability. A client that
holds an incomplete request can occupy admission until `stop()` cancels it;
add an admission deadline before production use. Cancellation tests cover idle
accept, incomplete request heads, upstream response headers/body and a
non-reading downstream client. The successful native fixture is MP3 only.
