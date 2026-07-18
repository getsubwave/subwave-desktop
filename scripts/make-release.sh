#!/usr/bin/env bash
# Build the release artifacts for SUB/WAVE Desktop: macOS DMG + Windows zip
# into dist/. With --publish, also create the GitHub release and upload them.
#
#   ./scripts/make-release.sh              # artifacts only
#   ./scripts/make-release.sh --publish    # artifacts + gh release vX.Y.Z
#
# Version comes from app.zon. macOS signing defaults to ad-hoc; set
# SIGN_IDENTITY="Developer ID Application: …" for a real identity.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

publish=false
[ "${1:-}" = "--publish" ] && publish=true

version="$(sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' app.zon | head -1)"
[ -n "$version" ] || { echo "error: could not read .version from app.zon" >&2; exit 1; }
app_name="SUBWAVE Player"
dmg="dist/SUBWAVE-Player-$version.dmg"
winzip="dist/SUBWAVE-Player-$version-windows-x64.zip"

echo "==> SUB/WAVE Desktop $version"

echo "==> SDK patches"
./scripts/apply-sdk-patches.sh

echo "==> tests"
native test

echo "==> macOS build + package"
native build
if [ -n "${SIGN_IDENTITY:-}" ]; then
    native package --target macos --signing identity --identity "$SIGN_IDENTITY"
else
    native package --target macos --signing adhoc
fi

echo "==> DMG"
rm -rf zig-out/dmg-stage
mkdir -p zig-out/dmg-stage dist
cp -R zig-out/package/subwave-desktop.app "zig-out/dmg-stage/$app_name.app"
ln -s /Applications zig-out/dmg-stage/Applications
codesign --verify --deep "zig-out/dmg-stage/$app_name.app"
hdiutil create -volname "$app_name" -srcfolder zig-out/dmg-stage -ov -format UDZO "$dmg" >/dev/null
hdiutil verify "$dmg" >/dev/null
echo "    $dmg"

echo "==> Windows build + package (cross-compiled, unsigned)"
native build -Dtarget=x86_64-windows-gnu
native package --target windows --binary zig-out/bin/subwave-desktop.exe
rm -f "$winzip"
(cd zig-out/package && zip -rq9 "$repo/$winzip" subwave-desktop-windows)
echo "    $winzip"

ls -lh "$dmg" "$winzip"

if $publish; then
    tag="v$version"
    if gh release view "$tag" >/dev/null 2>&1; then
        echo "==> release $tag exists — uploading assets (clobbering)"
        gh release upload "$tag" --clobber \
            "$dmg#$app_name $version (macOS, Apple Silicon)" \
            "$winzip#$app_name $version (Windows x64, untested)"
    else
        echo "==> creating release $tag"
        gh release create "$tag" \
            "$dmg#$app_name $version (macOS, Apple Silicon)" \
            "$winzip#$app_name $version (Windows x64, untested)" \
            --title "SUB/WAVE Desktop $version" \
            --generate-notes
    fi
    gh release view "$tag" --json url --jq .url
fi
