#!/usr/bin/env bash
# Install the .deb, .rpm and pacman package on the distros they are for and
# check what landed.
#
# The dependency lists in packaging/nfpm/nfpm.yaml are written by hand —
# nothing derives them — so a renamed or misspelt package name only shows up
# when a real package manager tries to resolve it. That is what this does, in
# throwaway containers: apt on Debian and Ubuntu, dnf on Fedora, zypper on
# openSUSE and pacman on Arch. A display-less
# container cannot launch the app, so the proof is that every dependency
# resolved, the files are in place, and the loader finds every linked library.
#
# Usage: scripts/test-linux-packages.sh <MAJOR.MINOR.PATCH> [package-dir]
set -euo pipefail

version="${1:-}"
dir="${2:-dist}"
if ! printf '%s' "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "usage: $0 <MAJOR.MINOR.PATCH> [package-dir]" >&2
    exit 2
fi
command -v docker >/dev/null 2>&1 || { echo "error: docker not found" >&2; exit 1; }

dir="$(cd "$dir" && pwd)"
deb="SUBWAVE-Player-${version}-linux-x64.deb"
rpm="SUBWAVE-Player-${version}-linux-x64.rpm"
arch="SUBWAVE-Player-${version}-linux-x64.pkg.tar.zst"
[ -f "$dir/$deb" ] || { echo "error: $dir/$deb not found" >&2; exit 1; }
[ -f "$dir/$rpm" ] || { echo "error: $dir/$rpm not found" >&2; exit 1; }
[ -f "$dir/$arch" ] || { echo "error: $dir/$arch not found" >&2; exit 1; }

# Runs inside each container once the package is installed. It travels as an
# environment variable so its own quotes and variables reach the container
# untouched by this shell.
verify='
    set -eu
    test -x /usr/bin/subwave-desktop
    test -f /usr/share/applications/dev.subwave.player.desktop
    test -f /usr/share/icons/hicolor/256x256/apps/dev.subwave.player.png
    if ldd /usr/bin/subwave-desktop | grep "not found"; then
        echo "error: unresolved libraries after install" >&2
        exit 1
    fi
    # The libraries the GTK host dlopen()s, which ldd cannot see.
    for lib in libgstreamer-1.0.so.0 libsoup-3.0.so.0; do
        ldconfig -p | grep -q "$lib" || { echo "error: $lib missing after install" >&2; exit 1; }
    done
'

# Ubuntu 24.04 is the oldest Ubuntu with GTK 4.12+, Debian 13 the oldest
# Debian; Fedora tracks latest because every supported Fedora clears the floor.
for image in ubuntu:24.04 debian:13; do
    echo "==> $deb on $image"
    docker run --rm -v "$dir:/pkgs:ro" -e VERIFY="$verify" -e DEBIAN_FRONTEND=noninteractive "$image" sh -c "
        set -eu
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends /pkgs/$deb >/dev/null
        dpkg -s subwave-desktop | grep -E '^(Version|Status):'
        sh -c \"\$VERIFY\"
    "
done

echo "==> $rpm on fedora:latest"
docker run --rm -v "$dir:/pkgs:ro" -e VERIFY="$verify" fedora:latest sh -c "
    set -eu
    dnf install -y -q --setopt=install_weak_deps=False /pkgs/$rpm >/dev/null
    rpm -q subwave-desktop
    sh -c \"\$VERIFY\"
"

# The same .rpm again: openSUSE names its packages differently, which is what
# the soname and "(a or b)" dependencies in nfpm.yaml are there to absorb.
# The package is unsigned, like every asset on the release.
echo "==> $rpm on opensuse/tumbleweed"
docker run --rm -v "$dir:/pkgs:ro" -e VERIFY="$verify" opensuse/tumbleweed:latest sh -c "
    set -eu
    zypper --non-interactive --quiet install --no-recommends --allow-unsigned-rpm /pkgs/$rpm >/dev/null
    rpm -q subwave-desktop
    sh -c \"\$VERIFY\"
"

echo "==> $arch on archlinux:latest"
docker run --rm -v "$dir:/pkgs:ro" -e VERIFY="$verify" archlinux:latest sh -c "
    set -eu
    pacman -Syu --noconfirm >/dev/null
    pacman -U --noconfirm /pkgs/$arch >/dev/null
    pacman -Q subwave-desktop
    sh -c \"\$VERIFY\"
"

echo "all packages install cleanly"
