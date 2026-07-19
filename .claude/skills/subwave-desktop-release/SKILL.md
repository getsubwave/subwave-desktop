---
name: subwave-desktop-release
description: Cut and publish a release of the SUB/WAVE desktop player — version bump, macOS DMG + Windows zip via scripts/make-release.sh, GitHub release, and announcement drafts. Use this whenever the user asks to release, ship, publish, or tag a new version of the desktop app, build a dmg/installer/windows build, upload release artifacts, or draft a release announcement — even if they only mention one piece (e.g. "make a new dmg" or "bump the version and ship it").
---

# SUB/WAVE Desktop release

This repo already carries the release machinery; this skill is the judgment
around it — preflight, versioning, publishing, verification, and the
announcement. The heavy lifting is one script (run from the repo root):

```bash
./scripts/make-release.sh              # preflight only, changes nothing
./scripts/make-release.sh --publish    # + create the release, follow the runs
```

**The script builds nothing.** All three artifacts come from CI, triggered by
`release: published`. The script reads the version from `app.zon`, refuses to
run unless main is clean and in sync, refuses to reuse an existing tag, and
**refuses to publish unless `ci.yml` is already green on this exact commit
across all three platforms** — v0.2.0 shipped half-populated because nothing
checked that. Then it creates the release and follows the three runs until
every asset is attached, failing if fewer than three arrive.

Useful flags: `--notes-file <path>` (instead of `--generate-notes`) and
`--skip-ci-check` for emergencies.

Because nothing is built locally, a release can be cut from any machine — it
no longer needs a Mac.

## Workflow

### 1. Preflight

- `git status` — the tag must point at what ships. Commit (or get the user to
  decide about) anything pending in `src/`, `app.zon`, or `scripts/` before
  publishing. Leave `.claude/`, `design-reference/`, and `dist/` alone; they're
  local by design.
- `./scripts/apply-sdk-patches.sh` — the installed `@native-sdk/cli` loses the
  local patches on EVERY npm upgrade, silently. The script is idempotent and
  the release script also runs it, but checking first gives a clearer error.
  Symptoms of lost patches: `native build` fails in `ui_markup.zig` around
  line 1014, or the red close button quits the app. Details and upstream
  issue links: `docs/sdk-notes.md` (vercel-labs/native#148, #149).
- If the SDK version changed since the last release (`native --version` vs
  what docs/sdk-notes.md mentions), run `native test` early and check the
  upstream issues — a fix may have shipped that lets a patch retire.

### 2. Version

`.version` in `app.zon` is the single source of truth — the script names the
artifacts and the tag from it. Bump it (patch for fixes, minor for features)
and commit the bump; a release from an unbumped version will try to clobber
the previous tag's assets, which is only right for re-cutting a botched build.

### 3. Build and publish

```bash
./scripts/make-release.sh --publish
```

- Takes ~10-15 minutes, nearly all of it waiting on the three runners
  (Windows is by far the slowest). The script prints each leg's status as it
  goes and exits non-zero if fewer than three assets land.
- **CI signs macOS ad-hoc.** There is no `SIGN_IDENTITY` path any more,
  because signing happens on a runner that holds no certificate. Giving CI a
  real Developer ID means putting a `.p12` plus an App Store Connect key into
  repository secrets and adding keychain setup to `release-macos.yml` first.
  Until that exists, never describe a DMG as notarized.
- `--publish` uses `--generate-notes`. For a release users will actually
  read, replace them: `gh release edit vX.Y.Z --notes-file …` with the shape
  used by v0.1.0 — what's new (concrete, feature-level), a download table
  with per-platform caveats, and build-from-source including the SDK patch
  step. Keep the honest flags: macOS ad-hoc = "right-click → Open on first
  launch"; Windows = "cross-compiled, not yet tested on real hardware —
  reports welcome" until someone actually has.

### 4. Verify before telling the user it's done

```bash
gh release view vX.Y.Z --json assets --jq '.assets[].name'
gh run list --workflow release-linux.yml --limit 1   # Linux leg
```

All three assets must be listed — DMG, Windows zip, and the Linux tarball
that CI attaches a few minutes later. For more than a smoke: mount the DMG
(`hdiutil attach … -nobrowse`), launch the app binary inside, detach. The
running dev copy of the app is unaffected — but if one is running from
`zig-out/`, rebuilding replaced its binary on disk; relaunch it after.

### 5. Announce (when asked)

Download URLs follow this pattern:

```
https://github.com/getsubwave/subwave-desktop/releases/download/vX.Y.Z/SUBWAVE-Player-X.Y.Z.dmg
https://github.com/getsubwave/subwave-desktop/releases/download/vX.Y.Z/SUBWAVE-Player-X.Y.Z-windows-x64.zip
https://github.com/getsubwave/subwave-desktop/releases/download/vX.Y.Z/SUBWAVE-Player-X.Y.Z-linux-x64.tar.gz
```

(The repo moved to the `getsubwave` org; `perminder-klair/subwave-desktop`
URLs still redirect but don't hand those out.)

For Discord/social drafts, read `references/announcement-voice.md` — the user
has a specific humanized voice for these (first person, concrete numbers, no
marketing gloss) and approved examples live there.

## Facts that keep biting

- **SDK patches vanish on upgrade** — see preflight. This has already
  happened once (0.5.2 → 0.5.3 wiped both patches mid-day).
- **The app keeps running from the tray after its window closes** (that's the
  close-hides patch working). `pkill -f zig-out/bin/subwave-desktop` before
  builds if a stale instance holds the binary.
- Windows builds cross-compile from macOS (`-Dtarget=x86_64-windows-gnu`,
  zig's mingw headers) and package with
  `native package --target windows --binary zig-out/bin/subwave-desktop.exe` —
  no Windows machine needed to build, but one IS needed to honestly claim it
  works.
- **All three artifacts are also built by CI**, one workflow per platform
  (`release-macos.yml`, `release-windows.yml`, `release-linux.yml`), triggered
  by `release: published`. So `--publish` starts them automatically and the CI
  assets land a few minutes after the script's own upload, clobbering it with
  an equivalent build. Don't announce until all three are listed; re-run a
  failed leg with `gh workflow run release-<os>.yml -f tag=vX.Y.Z`.
- Linux exists ONLY as CI — it cannot be cross-compiled from the Mac (the
  binary links the GTK4 system stack, 113 shared libraries, nothing bundled).
- Two runner pins are load bearing. `ubuntu-24.04`: ubuntu-22.04 ships GTK 4.6
  and the fractional-HiDPI patch is gated on `GTK_CHECK_VERSION(4, 12, 0)`, so
  an older runner silently compiles the fix out and ships pixelated text.
  `windows-latest`: the point is launching the app on real Windows under
  `-Dautomation=true`, which is what retires the "untested on real hardware"
  caveat. If that smoke test proves unreachable in a runner's service session,
  narrow it to launch-and-survive rather than deleting it.
- CI signs macOS **ad-hoc**, same as the script's default. Don't describe a
  CI-built DMG as notarized.
- Linux artifact requires glibc 2.39+ and GTK4 — Ubuntu 24.04+, Fedora 40+,
  Arch. Ubuntu 22.04 and Debian 12 users build from source; say so rather
  than implying it runs everywhere.
