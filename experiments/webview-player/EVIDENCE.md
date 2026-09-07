# WebView runtime proof evidence

Date: 2026-09-07. Baseline `b2ffb98`; branch `feat/webview-runtime-proof`.
This experiment leaves the shipping player intact.

## Decision

Proceed with named platform gates pending; not production-ready. Linux audio,
bridge and packaged-asset seams support further development. macOS and Windows
runtime checks remain required gates. The remaining Linux measurements and
lifecycle limits below also prevent production signoff.

## Environment and method

- Native SDK 0.10.1, commit `064ca98`; Zig 0.16.0; Node 24.19.0.
- Linux 7.2.3-arch1-3 x86_64, Ryzen AI 9 HX 370, 24 logical CPUs, ~31 GiB RAM.
- GTK 4.22.4, WebKitGTK 2.52.6, PipeWire 1.6.8, Hyprland/Wayland.
  Display: 3840 x 2160 at 60 Hz, scale 1.6.
- Separate application ID, temporary configuration/cache/log directories and
  a literal-loopback MP3 fixture. No production station or preferences used.
- Repeating 440 Hz MP3, 128 kbit/s, paced at 1600 bytes per 100 ms.
  A temporary PulseAudio null sink prevented sound through the user's speakers.
  FFmpeg captured decoded PCM from that sink's monitor.
- System WebViews: the installed Windows Chromium backend explicitly lacks
  native audio support. No Node server is required by the packaged interface.

## SDK seams established

The React scaffold (`native init --frontend react`) owns a Zig launcher and
runtime. React/TypeScript supplies the WebView interface; this is a different
rendering path from the SDK's default compiled TypeScript plus `.native` UI.
Changing the core language alone does not add CSS styling or browser animation.

The host calls `PlatformServices.audioLoadUrl`, waits for the native `.loaded`
audio event, then calls `audioPlay`. Pause, stop and volume use the same native
service owner. `Runtime.emitWindowEvent` reaches `window.zero.on`; snapshots
and native 32-band byte spectra are delivered separately. Each view permits
one outstanding spectrum delivery and one replaceable pending sample.

Each secondary WebView must register its own `.assets` source, including its
asset root. A URL-only mini view failed on the real host despite browser tests
passing. The mini now uses the bundled entry with `?view=mini`.

## Functional verification

- Existing app baseline: `native check`, 110/110 native tests, and ReleaseFast
  `native build -Dtrace=off` passed.
- Proof: 13/13 native tests, 14/14 frontend tests, 5/5 real HTTP fixture tests,
  TypeScript checking and 2/2 Playwright contract tests passed. Browser tests
  use a fake host and do not establish native audio or platform behavior.
- Real native decoded PCM: baseline mean -23.6 dB / peak -20.4 dB; WebView
  proof mean -21.6 dB / peak -18.5 dB, each from a two-second monitor capture.
- Both real WebViews became ready and ACKed actual native spectra. One sample
  recorded 8,063 received, 16,109 delivered and 16,109 ACKed across both views;
  capacity remained one pending sample per view, with one load/stream.
- Pause/resume, explicit hide/show, mini lifecycle and reload retained one
  native session. Forced fixture disconnect surfaced `error`; malformed
  commands and invalid volume returned `invalid_request`.
- Independent reviews corrected post-stop spectrum forwarding, sequence reuse,
  synchronous-load error handling, revision-gap recovery races, hidden-main
  snapshot resynchronization, and DNS-based loopback acceptance.
- Linux ReleaseFast directory package launches from `/tmp/subwave-package-run`
  without a frontend dev server. React completed its own handshake before any
  automation snapshot. A real packaging defect was found and fixed: SDK 0.10.1
  leaves frontend asset roots relative to the working directory on Linux. The
  proof resolves the shared root beside the executable for both views.
- Windows x86_64 GNU cross-build produced an executable and WebView2Loader.dll.
  This is compilation evidence only. macOS/Windows runtime hosts were unavailable.

## Final Linux package run

The final ReleaseFast package ran from `/tmp/subwave-package-run` with no dev
server. [Lifecycle assertions](evidence/linux-package-lifecycle.json) establish
both WebViews' own readiness, real FFT delivery, hidden-main snapshot suspension,
immediate snapshot convergence on show and on mini close, and one native load
and fixture stream through close/reopen. No automation snapshot was requested
before the first readiness assertion.

AT-SPI actions on the real mini window's Pause and Play buttons produced native
paused revision 5 and playing revision 6. This supplements the fake-host browser
tests with actual mini-origin command routing. At volume 0.6, the final package
produced decoded PCM (mean -26.0 dB, peak -22.9 dB). At volume zero, the monitor
capture reached FFmpeg's -91.0 dB floor. Reload preserved native load count 1,
both views reconnected, and fixture active/total counts remained 1/1.
A final forced disconnect reached the native error state after buffered audio
was exhausted (the initial one-second assertion was too short). Stop suppressed
further spectrum delivery; explicit Play recovered with native load count 2.
The backend made a connection retry during disconnect, so fixture totals after
failure/recovery are not used as the UI-lifecycle single-load assertion.
See [recovery observations](evidence/linux-package-recovery.json).
Terminating the test process while playing closed the fixture stream and left
no player process or audio sink input. The fixture and temporary sink were then
removed. Normal OS window-close behavior remains a separate platform check.

## Measurements

Raw samples and the Linux `/proc` sampler are in [evidence/](evidence/).
CPU is percent of one core, aggregated over the player and descendants. RSS is
summed across these processes and can count shared pages more than once; it is
not unique physical memory. Values are observations, not production budgets.

| Run | Duration | Mean CPU, one core | Peak summed RSS |
| --- | ---: | ---: | ---: |
| Existing native player, ReleaseFast | 300.34 s | 42.78% | 232.6 MiB |
| Two WebViews playing, Debug | 300.33 s | 10.42% | 962.6 MiB |
| Packaged main idle, ReleaseFast | 300.34 s | 0.62% | 441.1 MiB |
| Packaged main hidden, mini playing, ReleaseFast | 300.51 s | 10.66% | 751.9 MiB |

The build modes and view counts differ. These results neither prove a CPU
improvement nor establish an acceptable memory regression. Both proof windows
were logically visible, but the user could switch workspaces; continuous
on-screen visibility was not controlled. Pixel appearance and frame pacing
were not captured. No screenshots of unrelated desktop content are retained.

During the hidden-main sample, main received no new FFT deliveries while mini
continued to ACK samples. The host retained one native load and bounded pending
capacity one. This is not an all-windows-hidden benchmark. Command-to-render
latency, display-scale comparison and matching ReleaseFast visible-player
measurements remain pending. An exploratory mixed-action run is excluded from steady-state figures.
Ten volume-command-to-authoritative-snapshot checks took 160.5–326.4 ms,
median 225.0 ms ([samples](evidence/linux-command-latency.json)).
This includes launching the automation CLI, command handling, a second snapshot
request and possible response-file contention. It is not UI render latency.

Numeric acceptance budgets must be set after comparable controlled samples;
no missing measurement is replaced with an estimate.

## Remaining release gates

- Packaged runtime parity on macOS and Windows, including native PCM, FFT,
  mute, reload, failed streams, mini lifecycle and clean shutdown.
- OS-driven minimize/occlusion: the current app event surface does not fully
  expose these states. Explicit proof hide controls are the tested boundary;
  all-hidden animation suppression is not established.
- Native audio events have no load token. Production station switching and
  reconnect need serialized teardown/load or an SDK event-token extension.
- A reloaded/ready view waits for the next live FFT frame. Retaining the newest
  sample for a paused reload remains a defined follow-on requirement.
- Production credentials, station polling/reconnect, settings migration,
  tray/notifications/Discord, installer integration and designed UI are future
  work. The controls here are a diagnostic panel.
- Production builds must scope development origins to development. This proof
  allows the exact local Vite origin; automation builds additionally authorize
  the CLI's `zero://inline` bridge origin. Redirect/navigation adversarial
  runtime testing remains pending beyond the declared exact-origin policy.

## Automation caveat

The SDK automation bridge uses a shared response file that live FFT ACKs can
overwrite. The verification helper matches request IDs and retries only reads;
mutations are checked against subsequent authoritative state and stream counts.
A native `snapshot` invocation itself marks its source view ready. Real WebView
readiness must therefore be checked with `diagnostics` before requesting a
snapshot; otherwise automation can mask a failed frontend load.
