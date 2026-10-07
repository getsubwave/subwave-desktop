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
patch_sdk_version="0.10.1"

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

# Check every hunk before changing anything. A helper-name marker alone cannot
# distinguish a complete patch from one whose rendering call sites reverted.
# --force prevents patch from guessing the direction; --fuzz=0 and the offset
# check require the exact version/layout this patch was generated against.
# macOS patch is quiet by default, including about offsets. Request verbose
# dry runs explicitly so the offset check works with both BSD and GNU patch.
if reverse_check="$(LC_ALL=C patch --verbose --batch --force --reverse --dry-run --fuzz=0 -p1 -d "$sdk" < "$patch_file" 2>&1)" &&
    [[ "$reverse_check" != *offset* ]]; then
    echo "already applied, every hunk verified ($(native --version))"
    exit 0
fi

if ! forward_check="$(LC_ALL=C patch --verbose --batch --force --forward --dry-run --fuzz=0 -p1 -d "$sdk" < "$patch_file" 2>&1)" ||
    [[ "$forward_check" == *offset* ]]; then
    echo "error: SDK patch is incomplete or its source layout has drifted; no files changed." >&2
    printf '%s\n' "$forward_check" >&2
    echo "re-install @native-sdk/cli@$patch_sdk_version, then re-run this script" >&2
    exit 1
fi

LC_ALL=C patch --batch --force --forward --fuzz=0 -p1 -d "$sdk" < "$patch_file"
echo "applied to $sdk ($(native --version))"
echo "verify with: native test"
