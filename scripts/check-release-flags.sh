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
set -euo pipefail

fail=0
for wf in release-windows release-macos release-linux ci; do
  file=".github/workflows/${wf}.yml"
  while IFS= read -r line; do
    case "$line" in
      *"-Dtrace=off"*) ;;
      *) echo "error: ${file}: 'native build' without -Dtrace=off:${line}" >&2; fail=1 ;;
    esac
  done < <(grep -n 'native build' "$file")
done

if [ "$fail" -ne 0 ]; then
  echo "error: see docs/sdk-trace-log-request.md and issue #23" >&2
  exit 1
fi
echo "ok: every 'native build' passes -Dtrace=off"
