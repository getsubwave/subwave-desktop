#!/usr/bin/env bash
# Rewrite the startup window's close_policy in app.zon.
#
# Why this exists: SDK 0.6.0 made close-to-hide (the menu-bar-app shape) a
# first-class manifest field, but it is validated against the BUILD TARGET at
# comptime and app.zon has no per-platform scoping:
#
#   macos   - "hide" always allowed (the Dock reopen path always exists)
#   windows - "hide" allowed, but only with the "tray" capability declared
#   linux   - "hide" is a hard compile error (the GTK host has no tray, so a
#             hidden window would be stranded with nothing to bring it back)
#
# So the checked-in manifest declares "quit" (the Linux-safe default, and what
# `native test` / `native build` use on this repo's Linux dev box), and the
# macOS + Windows release workflows call this to flip it to "hide" before they
# build. See docs/sdk-notes.md.
#
# Usage: scripts/set-close-policy.sh <quit|hide>
set -euo pipefail

policy="${1:-}"
case "$policy" in
    quit | hide) ;;
    *)
        echo "usage: $0 <quit|hide>" >&2
        exit 2
        ;;
esac

repo="$(cd "$(dirname "$0")/.." && pwd)"
manifest="$repo/app.zon"
[ -f "$manifest" ] || { echo "error: $manifest missing" >&2; exit 1; }

current="$(sed -n 's/.*\.close_policy = "\([^"]*\)".*/\1/p' "$manifest" | head -1)"
if [ -z "$current" ]; then
    echo "error: no .close_policy found in app.zon — the manifest drifted, so the" >&2
    echo "       release build would silently ship the wrong close behavior" >&2
    exit 1
fi

if [ "$current" = "$policy" ]; then
    echo "close_policy already \"$policy\""
    exit 0
fi

# Write through a temp file: macOS ships BSD sed (`-i` needs an argument) and
# the Linux/Git-Bash runners ship GNU sed, and this works on both.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
sed 's/\.close_policy = "'"$current"'"/.close_policy = "'"$policy"'"/' "$manifest" >"$tmp"
mv "$tmp" "$manifest"
trap - EXIT

verify="$(sed -n 's/.*\.close_policy = "\([^"]*\)".*/\1/p' "$manifest" | head -1)"
[ "$verify" = "$policy" ] || { echo "error: rewrite did not take (still \"$verify\")" >&2; exit 1; }
echo "close_policy \"$current\" -> \"$policy\""
