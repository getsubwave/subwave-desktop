#!/usr/bin/env bash
# Fail if an x86-64 binary contains AVX/AVX-512 instructions.
#
# v0.2.1 shipped a Windows exe with 1,383 AVX-512 instructions because the CI
# runner's Ice Lake CPU leaked into a plain `native build` (Zig's native target
# includes the host's CPU features). On any machine without AVX-512 — most
# consumer CPUs, including every officially supported Windows 11 chip from
# Intel 12th-14th gen and AMD Zen 3 — the app died on an illegal instruction
# at startup with no dialog. The smoke test never caught it: it runs on the
# same runner that built the binary.
#
# Release builds pin -Dcpu=baseline; this audit proves the pin held. Baseline
# x86-64 is SSE2-only, so a single ymm/zmm register reference means the build
# was not baseline. Matching [yz]mm followed by a digit avoids false positives
# from symbol names (e.g. "symmetric" contains "ymm").
set -euo pipefail

bin="${1:?usage: audit-cpu-baseline.sh <x86-64 binary>}"
[ -f "$bin" ] || { echo "error: no such file: $bin" >&2; exit 1; }

# GNU objdump (Linux), llvm-objdump (macOS CLT exposes it as objdump; Windows
# runners carry it in the LLVM install). Failing loudly when none is found
# keeps the audit from silently not running — that is how v0.2.1 shipped.
if command -v objdump >/dev/null 2>&1; then
    od=objdump
elif command -v llvm-objdump >/dev/null 2>&1; then
    od=llvm-objdump
elif [ -x "/c/Program Files/LLVM/bin/llvm-objdump.exe" ]; then
    od="/c/Program Files/LLVM/bin/llvm-objdump.exe"
else
    echo "error: no objdump/llvm-objdump on this runner; cannot audit $bin" >&2
    exit 1
fi

count="$("$od" -d "$bin" | grep -cE '[yz]mm[0-9]' || true)"
if [ "$count" -ne 0 ]; then
    echo "error: $bin contains $count AVX/AVX-512 register references." >&2
    echo "The release build must be -Dcpu=baseline or it will not start on" >&2
    echo "CPUs older than the CI runner's. See this script's header." >&2
    exit 1
fi
echo "cpu baseline audit ok: no AVX/AVX-512 in $bin ($od)"
