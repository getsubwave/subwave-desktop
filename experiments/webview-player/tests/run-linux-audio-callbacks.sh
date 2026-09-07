#!/usr/bin/env bash
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
experiment_dir="$(cd "$test_dir/.." && pwd)"
repo_root="$(cd "$experiment_dir/../.." && pwd)"
sdk_root="${1:-$repo_root/.superpowers/player-transport-sdk}"
sdk_linux="$(realpath "$sdk_root")/src/platform/linux"
test -f "$sdk_linux/gtk_host.c"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/subwave-audio-callbacks.XXXXXX")"
trap 'rm -rf -- "$check_dir"' EXIT
output="$check_dir/check"

read -r -a pkg_flags <<<"$(pkg-config --cflags --libs gtk4 webkitgtk-6.0)"

cc -std=c11 -D_GNU_SOURCE -O0 -g \
  -ffunction-sections -fdata-sections -Wl,--gc-sections \
  -I"$sdk_linux" \
  "$test_dir/linux_audio_callbacks.c" \
  "${pkg_flags[@]}" -ldl -lm \
  -o "$output"

"$output"
echo "linux audio callback identity harness passed"
