#!/usr/bin/env bash
# Point this AUR package at a published release: set pkgver, reset pkgrel,
# recompute the checksums from the release assets and regenerate .SRCINFO.
#
# makepkg tooling only exists on Arch. On an Arch machine (updpkgsums comes
# from pacman-contrib) it runs right here; anywhere else the work runs in an
# archlinux container, which keeps this usable from the Debian dev box and
# from a GitHub runner alike. The release has to be published first:
# updpkgsums downloads the tarball it checksums.
#
# Usage: packaging/aur/bump.sh <MAJOR.MINOR.PATCH>
set -euo pipefail

version="${1:-}"
if ! printf '%s' "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "usage: $0 <MAJOR.MINOR.PATCH>" >&2
    exit 2
fi
native=0
if command -v updpkgsums >/dev/null 2>&1 && command -v makepkg >/dev/null 2>&1; then
    native=1
elif ! command -v docker >/dev/null 2>&1; then
    echo "error: need either makepkg + updpkgsums (Arch, pacman-contrib) or docker" >&2
    exit 1
fi

dir="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
sed -e "s/^pkgver=.*/pkgver=$version/" -e "s/^pkgrel=.*/pkgrel=1/" "$dir/PKGBUILD" >"$tmp"
cat "$tmp" >"$dir/PKGBUILD"

if [ "$native" -eq 1 ]; then
    # In a scratch copy, so the downloaded sources never land in the tree.
    work="$(mktemp -d)"
    trap 'rm -f "$tmp"; rm -rf "$work"' EXIT
    cp "$dir/PKGBUILD" "$dir"/*.desktop "$work/"
    (cd "$work" && updpkgsums && makepkg --printsrcinfo >.SRCINFO)
    cat "$work/PKGBUILD" >"$dir/PKGBUILD"
    cat "$work/.SRCINFO" >"$dir/.SRCINFO"
    grep -E '^\s*(pkgver|pkgrel|sha256sums) =' "$dir/.SRCINFO"
    exit 0
fi

# Write results back with `cat >` into files that already exist on the host,
# so they keep the caller's ownership instead of turning root-owned.
touch "$dir/.SRCINFO"
docker run --rm -v "$dir:/pkg" archlinux:latest bash -euo pipefail -c '
    pacman -Sy --noconfirm --needed pacman-contrib >/dev/null
    useradd -m builder
    install -d -o builder /home/builder/pkg
    cp /pkg/PKGBUILD /pkg/*.desktop /home/builder/pkg/
    chown -R builder /home/builder/pkg
    cd /home/builder/pkg
    su builder -c "updpkgsums && makepkg --printsrcinfo > .SRCINFO"
    cat PKGBUILD >/pkg/PKGBUILD
    cat .SRCINFO >/pkg/.SRCINFO
'
grep -E '^\s*(pkgver|pkgrel|sha256sums) =' "$dir/.SRCINFO"
