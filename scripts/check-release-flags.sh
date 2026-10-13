#!/usr/bin/env bash
# Every shipping build MUST pass -Dtrace=off.
#
# The SDK's default -Dtrace=events writes one runtime.event record per
# rendered frame and per audio callback, and debug.appendFile does a full
# open/stat/write/close for each one — inline on the platform message loop
# thread (windowsCallback -> RunState.emit -> handler, all synchronous).
# On Windows behind an AV minifilter that scans on open and close, against a
# log file that grows without bound, this stalls the message pump: no
# WM_PAINT, a white client area, and a busy cursor on minimize/resize, at
# near-zero CPU. That is issue #23.
#
# This guard exists because the flag lives in YAML that nothing else tests.
# Drop it and the bug ships again silently.
#
# It also pins the distribution channel. The checked-in src/distribution.zig
# must say .github, because that is what every GitHub release ships, and none
# of the GitHub release workflows may flip it to store. A store workflow flips
# it on its own runner with scripts/set-distribution.sh, after this guard runs.
# A committed or misplaced flip would silently drop the update notice from the
# builds people download from GitHub.
set -euo pipefail

fail=0
for wf in release-windows release-macos release-linux ci; do
  file=".github/workflows/${wf}.yml"
  n=0
  while IFS= read -r line; do
    n=$((n + 1))
    # Strip from the first '#' on, so prose that names the command cannot
    # trip the guard — only what the shell would actually run is inspected.
    code="${line%%#*}"
    case "$code" in
      *"native build"*) ;;
      *) continue ;;
    esac
    case "$code" in
      *"-Dtrace=off"*) ;;
      *) echo "error: ${file}:${n}: 'native build' without -Dtrace=off:${code}" >&2; fail=1 ;;
    esac
  done < "$file"
done

if [ "$fail" -ne 0 ]; then
  echo "error: see docs/sdk-trace-log-request.md and issue #23" >&2
  exit 1
fi
echo "ok: every 'native build' passes -Dtrace=off"

channel="$(sed -n 's/^pub const channel: Channel = \.\([a-z_]*\);$/\1/p' src/distribution.zig | head -1)"
if [ "$channel" != "github" ]; then
  echo "error: src/distribution.zig declares channel '${channel:-<none found>}'; the committed value must be github" >&2
  echo "       (store workflows flip it on their own runner with scripts/set-distribution.sh)" >&2
  exit 1
fi
for wf in release-windows release-macos release-linux; do
  file=".github/workflows/${wf}.yml"
  n=0
  while IFS= read -r line; do
    n=$((n + 1))
    code="${line%%#*}"
    case "$code" in
      *"set-distribution.sh store"*)
        echo "error: ${file}:${n}: a GitHub release workflow flips to the store channel" >&2
        exit 1
        ;;
    esac
  done < "$file"
done
echo "ok: GitHub release builds ship the github distribution channel"
