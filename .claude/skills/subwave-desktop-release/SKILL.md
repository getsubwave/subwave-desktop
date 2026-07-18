---
name: subwave-desktop-release
description: Cut and publish a release of the SUB/WAVE desktop player — version bump, macOS DMG + Windows zip via scripts/make-release.sh, GitHub release, and announcement drafts. Use this whenever the user asks to release, ship, publish, or tag a new version of the desktop app, build a dmg/installer/windows build, upload release artifacts, or draft a release announcement — even if they only mention one piece (e.g. "make a new dmg" or "bump the version and ship it").
---

# SUB/WAVE Desktop release

This repo already carries the release machinery; this skill is the judgment
around it — preflight, versioning, publishing, verification, and the
announcement. The heavy lifting is one script (run from the repo root):

```bash
./scripts/make-release.sh              # artifacts only → dist/
./scripts/make-release.sh --publish    # + create/update GitHub release vX.Y.Z
```

It reads the version from `app.zon`, re-applies the local SDK patches, gates on
`native test`, builds + packages macOS (DMG, verified) and Windows x64 (zip,
cross-compiled), and with `--publish` creates the release or clobber-uploads
assets onto an existing tag.

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

- Takes ~4 minutes. Signing defaults to ad-hoc; when the user has a
  Developer ID certificate, `SIGN_IDENTITY="Developer ID Application: …"`
  switches to it (check `security find-identity -v -p codesigning` — "Apple
  Development" certs are NOT distribution certs and won't help Gatekeeper).
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
- **Linux is built by CI, not by this script.** It cannot be cross-compiled
  from the Mac (the binary links the GTK4 system stack, 113 shared libraries,
  nothing bundled), so `.github/workflows/release-linux.yml` builds it on
  `ubuntu-24.04` and uploads the tarball onto the release. It triggers on
  `release: published`, so `--publish` starts it automatically — the Linux
  asset lands a few minutes AFTER the macOS and Windows ones. Don't announce
  before it appears; re-run it with
  `gh workflow run release-linux.yml -f tag=vX.Y.Z` if it failed.
- The ubuntu-24.04 pin is load bearing: ubuntu-22.04 ships GTK 4.6 and the
  fractional-HiDPI patch is gated on `GTK_CHECK_VERSION(4, 12, 0)`, so an
  older runner would silently compile the fix out and ship pixelated text.
- Linux artifact requires glibc 2.39+ and GTK4 — Ubuntu 24.04+, Fedora 40+,
  Arch. Ubuntu 22.04 and Debian 12 users build from source; say so rather
  than implying it runs everywhere.
