#!/usr/bin/env bash
# Build the .deb, .rpm and pacman package from a packaged Linux build.
#
# All three repackage zig-out/package/subwave-desktop-linux — the same tree the
# release tarball is made from — so run `native package --target linux` (and
# the strip step, at release time) first. Nothing is compiled here.
#
# nfpm does the work (packaging/nfpm/nfpm.yaml). One on PATH is used as is;
# otherwise the pinned release below is downloaded and checksummed, for the
# same reason setup-native checksums Zig: these are the files people install
# as root, so a tampered download has to fail the job rather than ship.
#
# Usage: scripts/package-linux-distros.sh <MAJOR.MINOR.PATCH> [output-dir]
#   Writes <output-dir>/SUBWAVE-Player-<version>-linux-x64.deb, .rpm and
#   .pkg.tar.zst
#   (output-dir defaults to dist/).
set -euo pipefail

nfpm_version="2.48.0"
nfpm_sha256="6d7f9a28b2f397934403950fcbba83f598b08d02edbe79a0815b3b4897341750"

version="${1:-}"
out="${2:-dist}"
if ! printf '%s' "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "usage: $0 <MAJOR.MINOR.PATCH> [output-dir]" >&2
    exit 2
fi

cd "$(dirname "$0")/.."

root="zig-out/package/subwave-desktop-linux"
if [ ! -x "$root/bin/subwave-desktop" ]; then
    echo "error: $root/bin/subwave-desktop not found — run 'native package --target linux' first" >&2
    exit 1
fi

if command -v nfpm >/dev/null 2>&1; then
    nfpm="nfpm"
else
    case "$(uname -s)-$(uname -m)" in
        Linux-x86_64) ;;
        *) echo "error: no nfpm on PATH, and the pinned download is Linux x86_64 only" >&2; exit 1 ;;
    esac
    tools=".zig-cache/nfpm-$nfpm_version"
    if [ ! -x "$tools/nfpm" ]; then
        mkdir -p "$tools"
        archive="$tools/nfpm.tar.gz"
        curl -fsSL -o "$archive" \
            "https://github.com/goreleaser/nfpm/releases/download/v${nfpm_version}/nfpm_${nfpm_version}_Linux_x86_64.tar.gz"
        echo "$nfpm_sha256  $archive" | sha256sum -c - >/dev/null || {
            echo "error: nfpm $nfpm_version checksum mismatch" >&2
            rm -f "$archive"
            exit 1
        }
        tar -xzf "$archive" -C "$tools" nfpm
        rm -f "$archive"
    fi
    nfpm="$tools/nfpm"
fi

mkdir -p "$out"
for fmt in deb rpm archlinux; do
    ext="$fmt"
    [ "$fmt" = archlinux ] && ext="pkg.tar.zst"
    target="$out/SUBWAVE-Player-${version}-linux-x64.${ext}"
    VERSION="$version" "$nfpm" package \
        --config packaging/nfpm/nfpm.yaml --packager "$fmt" --target "$target"
    ls -lh "$target"
done
