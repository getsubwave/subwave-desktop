#!/usr/bin/env bash
# Exercise the patch installer on disposable SDK trees, never the real SDK.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
installed="$(npm root -g)/@native-sdk/cli"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
host="src/platform/linux/gtk_host.c"
patch_file="$repo/patches/native-sdk-local.patch"
mkdir -p "$work/pristine/$(dirname "$host")"
cp "$installed/$host" "$work/pristine/$host"
cp "$installed/package.json" "$work/package.json"
# The installed tree must carry the complete, current patch.
patch --batch --force --reverse --fuzz=0 -p1 -d "$work/pristine" < "$patch_file" > "$work/reverse.log"

export npm_config_prefix="$work/sdk prefix"
fixture="$(npm root -g)/@native-sdk/cli"
reset_fixture() {
    rm -rf "$fixture"
    mkdir -p "$fixture/$(dirname "$host")"
    cp "$work/pristine/$host" "$fixture/$host"
    cp "$work/package.json" "$fixture/package.json"
}
run_installer() {
    bash "$repo/scripts/apply-sdk-patches.sh" > "$work/result.log" 2>&1
}
expect_rejected() {
    cp "$fixture/$host" "$work/before.c"
    if run_installer; then
        echo "error: accepted $1" >&2
        cat "$work/result.log" >&2
        exit 1
    fi
    cmp "$work/before.c" "$fixture/$host"
    echo "ok: rejects $1 without changing the SDK"
}

reset_fixture
run_installer
patch --batch --force --reverse --dry-run --fuzz=0 -p1 -d "$fixture" < "$patch_file" > "$work/complete.log"
cp "$fixture/$host" "$work/patched.c"
run_installer
cmp "$work/patched.c" "$fixture/$host"
echo "ok: applies a pristine SDK and leaves a complete patch unchanged"

# Keep the helper/marker but revert one rendering call site. The old installer
# incorrectly treated this as fully applied, silently losing the HiDPI fix.
SDK_HOST="$fixture/$host" node --input-type=commonjs <<'JS'
const fs = require('node:fs');
const path = process.env.SDK_HOST;
const source = fs.readFileSync(path, 'utf8');
fs.writeFileSync(path, source.replace(
    'const double scale = native_sdk_widget_device_scale(view->widget);',
    'const double scale = (double)gtk_widget_get_scale_factor(view->widget);'
));
JS
expect_rejected "a partially applied patch"

reset_fixture
SDK_PACKAGE_JSON="$fixture/package.json" node --input-type=commonjs <<'JS'
const fs = require('node:fs');
fs.writeFileSync(process.env.SDK_PACKAGE_JSON, JSON.stringify({version: '0.0.0'}));
JS
expect_rejected "a different SDK version"

reset_fixture
{ printf '\n'; cat "$fixture/$host"; } > "$work/offset.c"
cp "$work/offset.c" "$fixture/$host"
expect_rejected "hunks shifted by an offset"

# The already-applied check must reject offsets too, rather than declaring a
# drifted tree complete. Exercise BSD patch with its verbosity disabled by
# the environment; the installer's explicit --verbose must still report it.
export PATCH_VERBOSE=0
cp "$work/patched.c" "$fixture/$host"
{ printf '\n'; cat "$fixture/$host"; } > "$work/offset.c"
cp "$work/offset.c" "$fixture/$host"
expect_rejected "a fully applied patch shifted by an offset"
