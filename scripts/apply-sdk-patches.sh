#!/usr/bin/env bash
# Re-apply the local Native SDK patches after an `npm i -g @native-sdk/cli`
# upgrade. Safe to run repeatedly — it no-ops when the patches are present.
# See docs/sdk-notes.md for what each patch does and why.
set -euo pipefail

sdk="$(npm root -g)/@native-sdk/cli"
repo="$(cd "$(dirname "$0")/.." && pwd)"
patch_file="$repo/patches/native-sdk-local.patch"

[ -d "$sdk" ] || { echo "error: @native-sdk/cli not found at $sdk" >&2; exit 1; }
[ -f "$patch_file" ] || { echo "error: $patch_file missing" >&2; exit 1; }

quota_applied=false
close_applied=false
grep -q "Raise the quota BEFORE computing" "$sdk/src/primitives/canvas/ui_markup.zig" && quota_applied=true
grep -q "windowShouldClose" "$sdk/src/platform/macos/appkit_host.m" && close_applied=true

if $quota_applied && $close_applied; then
    echo "already applied ($(native --version))"
    exit 0
fi
if $quota_applied || $close_applied; then
    echo "error: patches partially applied — re-install the SDK, then re-run" >&2
    exit 1
fi

patch -p1 -d "$sdk" < "$patch_file"
echo "applied to $sdk ($(native --version))"
echo "verify with: native test"
