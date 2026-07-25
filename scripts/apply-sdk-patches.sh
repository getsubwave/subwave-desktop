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

# marker<TAB>file<TAB>description — one row per patch in native-sdk-local.patch.
# (The 0.5.x canonicalizeComptime-quota and close-hides-window patches are gone:
# both shipped upstream in SDK 0.6.0. See docs/sdk-notes.md.)
patches=$(cat <<'ROWS'
native_sdk_surface_device_scale	src/platform/linux/gtk_host.c	fractional HiDPI scale (Linux)
ROWS
)

applied=0
total=0
missing=""
while IFS=$'\t' read -r marker file desc; do
    [ -n "$marker" ] || continue
    total=$((total + 1))
    if grep -q "$marker" "$sdk/$file" 2>/dev/null; then
        applied=$((applied + 1))
    else
        missing="$missing  - $desc ($file)"$'\n'
    fi
done <<<"$patches"

if [ "$applied" -eq "$total" ]; then
    echo "already applied, $applied/$total ($(native --version))"
    exit 0
fi
if [ "$applied" -ne 0 ]; then
    echo "error: patches partially applied ($applied/$total). Missing:" >&2
    printf '%s' "$missing" >&2
    echo "re-install the SDK (npm i -g @native-sdk/cli), then re-run this script" >&2
    exit 1
fi

patch -p1 -d "$sdk" < "$patch_file"
echo "applied to $sdk ($(native --version))"
echo "verify with: native test"
