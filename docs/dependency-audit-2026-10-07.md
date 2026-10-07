# Dependency maintenance — 7 October 2026

This audit covers the shipping Zig/Native markup app on `main`. This tree has
no app-owned npm dependencies, `package.json`, or Zig package dependency list.
The React/WebView experiment is a separate branch and is outside this change.

## Toolchain and packages

| Component | Result | Decision |
| --- | --- | --- |
| Node | 24.19.0 → 24.21.0, latest published Node 24 release | Updated mise and CI to the same exact version; installed locally |
| Native SDK CLI | 0.10.1, still npm's latest published release | Reinstalled under Node 24.21.0 and applied the HiDPI patch |
| Zig | 0.16.0; upstream stable is 0.17.0 | Retained 0.16.0, required by this SDK; verified all four CI archive checksums against the official index |
| npm | 11.19.0 bundled with Node 24.21.0 | Used the selected Node distribution's package manager |
| SDK compiler dependencies | `scriptc` 0.0.35; `@typescript/old` aliases TypeScript 6.0.3 | Kept the SDK's exact dependency contracts; newer standalone versions do not establish SDK compatibility |
| Other SDK compiler packages | TypeScript 7.0.2 and `typescript5` 5.9.3 present in the fresh installation | SDK-managed tooling; no app TypeScript core to migrate |
| GitHub Actions | checkout v7.0.1, setup-node v7.0.0, upload-artifact v7.0.2 | Existing `@v7` references already follow these releases |

Live sources: [Node release index](https://nodejs.org/dist/index.json),
[Native SDK registry metadata](https://registry.npmjs.org/@native-sdk%2fcli),
[Native SDK releases](https://github.com/vercel-labs/native/releases),
[Zig download index](https://ziglang.org/download/index.json), and the release
APIs for [checkout](https://github.com/actions/checkout/releases),
[setup-node](https://github.com/actions/setup-node/releases), and
[upload-artifact](https://github.com/actions/upload-artifact/releases).

A fresh disposable npm lock for `@native-sdk/cli@0.10.1`, followed by
`npm audit --json`, reported **zero known vulnerabilities** across 35 resolved
dependencies, including optional platform packages. This is an npm advisory
check, not an audit of every native library or SDK source file.

Linux dependencies are supplied by the OS: locally GTK 4.22.5, GStreamer
1.28.7, GLib 2.88.3, Pango 1.58.2, and Cairo 1.18.6 were available. The player
links GTK/GStreamer; its package has no WebKit link. OS-wide package upgrades
and independent edits to SDK-vendored libraries are outside this app change.

## Fixes

- Verify all HiDPI patch hunks, rather than trusting a helper-name marker.
  Complete patches are idempotent; partial, shifted, or version-mismatched
  trees fail before mutation. Disposable integration cases run in CI.
- Reject signed, underscored, and leading-zero release components. Previously
  the integer parser could treat malformed tags as valid update notices.
- Guard duration, BPM, and temperature conversions against out-of-range and
  nonfinite station numbers. Use saturating millisecond arithmetic for track
  timestamps/durations. The original metadata tests reproduced an integer
  conversion panic and an elapsed-time overflow; regression coverage now
  exercises those cases and ordinary values.
- Declare four model fields as internal to remove misleading markup warnings.
- Disable tray registration/callbacks on Linux, where GTK has no tray service.
  The original live run produced 183 repeated `UnsupportedService` warnings
  in about six seconds as model rebuilds retried installation.
- Document installation under the pinned mise environment and pin the SDK
  version in the setup command.

## Validation and limits

The Zig suite passes **114/114 tests**; all nine markup files validate without
the original unbound-state warnings. Patch installer integration cases, shell
syntax, release trace flags, and `git diff --check` pass.

`zig fmt --check src/model.zig` also reports pre-existing formatting differences
on the unchanged `HEAD` version; a broad formatting rewrite is outside this
maintenance pass.

The Linux smoke probe uses isolated config/cache/state/data directories, a
local HTTP station, and silent MP3 audio. It checks rendering, oversized
metadata survival, recovery to ordinary metadata, pause/resume, decoded stream
playback, and zero dispatch errors. It captures a screenshot and reports the
fractional display scale as **1.6**. Playback and station metadata come from
the fixture, and saved listener settings are isolated. The app's ordinary
read-only directory and GitHub release checks retain their remote endpoints.

`native doctor` reports the relevant Linux dependencies available. Its
generic `--strict` mode still returns `DoctorProblems` because it treats the
Linux host's unsupported macOS codesigning check as a problem; this is an
upstream diagnostic limitation, not a missing Linux build dependency.

The final Linux release build and package pass with
`-Dcpu=baseline -Dtrace=off`; the packaged binary passes the CPU baseline
audit with no AVX/AVX-512 instructions. There are no missing linked libraries
or WebKit dependencies on this host. Windows and both macOS architectures remain
subject to the existing CI matrix; those platforms were not executed locally.
Maintenance branch: `chore/dependency-maintenance-2026-10-07`.

Local evidence is retained under `zig-out/maintenance-validation/`: screenshot,
runtime snapshot, empty app stderr log after the tray fix, and npm audit JSON.
The release package is `zig-out/package/subwave-desktop-linux/`.
