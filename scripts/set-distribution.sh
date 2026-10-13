#!/usr/bin/env bash
# Rewrite the distribution channel in src/distribution.zig.
#
# Why this exists: a store build (Microsoft Store, Snap Store, Mac App Store)
# must not poll GitHub Releases or point listeners at outside downloads — the
# store delivers updates itself — and the Mac App Store build also drops the
# Ko-fi link. The SDK's build graph passes no app-level -D options through to
# src/, so the channel is a checked-in constant, like close_policy in app.zon.
#
# The checked-in value is "github" (what every GitHub release ships), and
# scripts/check-release-flags.sh fails CI if it is committed as anything else.
# A store workflow calls this to flip it to "store" before it tests and builds.
#
# Usage: scripts/set-distribution.sh <github|store>
set -euo pipefail

channel="${1:-}"
case "$channel" in
    github | store) ;;
    *)
        echo "usage: $0 <github|store>" >&2
        exit 2
        ;;
esac

repo="$(cd "$(dirname "$0")/.." && pwd)"
source_file="$repo/src/distribution.zig"
[ -f "$source_file" ] || { echo "error: $source_file missing" >&2; exit 1; }

read_channel() {
    sed -n 's/^pub const channel: Channel = \.\([a-z_]*\);$/\1/p' "$source_file" | head -1
}

current="$(read_channel)"
if [ -z "$current" ]; then
    echo "error: no 'pub const channel: Channel = .<name>;' line in src/distribution.zig —" >&2
    echo "       the declaration drifted, so the build would silently ship the wrong channel" >&2
    exit 1
fi

if [ "$current" = "$channel" ]; then
    echo "distribution channel already \"$channel\""
    exit 0
fi

# Write through a temp file: macOS ships BSD sed (`-i` needs an argument) and
# the Linux/Git-Bash runners ship GNU sed, and this works on both.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
sed 's/^pub const channel: Channel = \.'"$current"';$/pub const channel: Channel = .'"$channel"';/' "$source_file" >"$tmp"
mv "$tmp" "$source_file"
trap - EXIT

verify="$(read_channel)"
[ "$verify" = "$channel" ] || { echo "error: rewrite did not take (still \"$verify\")" >&2; exit 1; }
echo "distribution channel \"$current\" -> \"$channel\""
