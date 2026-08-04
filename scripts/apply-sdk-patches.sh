#!/usr/bin/env bash
# Re-apply the local Native SDK patches after an `npm i -g @native-sdk/cli`
# upgrade. Safe to run repeatedly — it no-ops when the patches are present.
# See docs/sdk-notes.md for what each patch does and why.
set -euo pipefail

# The SDK version patches/native-sdk-local.patch was generated against. A
# unified diff carries no version of its own, and `patch` will happily land
# hunks on a DIFFERENT release by offset or fuzz — quietly patching the wrong
# lines, or reporting success against a tree the app can no longer build. Bump
# this together with .github/actions/setup-native's native-sdk-version whenever
# the patch is regenerated (docs/sdk-notes.md walks through it).
patch_sdk_version="0.8.0"

sdk="$(npm root -g)/@native-sdk/cli"
repo="$(cd "$(dirname "$0")/.." && pwd)"
patch_file="$repo/patches/native-sdk-local.patch"

[ -d "$sdk" ] || { echo "error: @native-sdk/cli not found at $sdk" >&2; exit 1; }
[ -f "$patch_file" ] || { echo "error: $patch_file missing" >&2; exit 1; }

# Read the version off the package being patched, not off `native --version`:
# this is the exact tree the hunks land in.
#
# The path goes through the ENVIRONMENT, never interpolated into the JS: on
# Windows `npm root -g` answers a backslash path (C:\npm\prefix\node_modules),
# and inside a string literal its separators are escape sequences — \n became a
# newline, require() got a mangled path, and this check failed the whole
# Windows leg. Keep node's error too; swallowing it is what turned a one-line
# escaping bug into a blank "could not read a version".
if ! installed_version="$(SDK_PACKAGE_JSON="$sdk/package.json" node -p "require(process.env.SDK_PACKAGE_JSON).version" 2>&1)"; then
    echo "error: could not read the installed SDK version from $sdk/package.json" >&2
    printf '       node: %s\n' "$installed_version" >&2
    exit 1
fi
case "$installed_version" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "error: $sdk/package.json gave an unexpected version '$installed_version'" >&2; exit 1 ;;
esac

if [ "$installed_version" != "$patch_sdk_version" ]; then
    echo "error: installed @native-sdk/cli is $installed_version, but" >&2
    echo "       patches/native-sdk-local.patch was generated against $patch_sdk_version." >&2
    echo >&2
    echo "Applying it anyway would land the hunks by offset/fuzz on a tree nobody" >&2
    echo "checked. Pick one:" >&2
    echo "  - install the expected SDK:  npm i -g @native-sdk/cli@$patch_sdk_version" >&2
    echo "  - or move to $installed_version: confirm the patch is still needed," >&2
    echo "    regenerate it against the new tarball, then bump BOTH" >&2
    echo "    patch_sdk_version here and native-sdk-version in" >&2
    echo "    .github/actions/setup-native/action.yml (docs/sdk-notes.md)." >&2
    exit 1
fi

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
