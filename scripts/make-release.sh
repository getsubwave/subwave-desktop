#!/usr/bin/env bash
# Cut a SUB/WAVE Desktop release.
#
#   ./scripts/make-release.sh              # preflight only, changes nothing
#   ./scripts/make-release.sh --publish    # + create the release, follow CI
#
# This script no longer builds anything. Artifacts come from CI — one workflow
# per platform, triggered by `release: published` — because Linux cannot be
# cross-compiled from a Mac (it links the GTK4 system stack) and because
# building Windows on Windows is what caught a decode-gate bug that had shipped
# since 0.1.0. Removing the local build also means a release can be cut from any
# machine, not just a Mac.
#
# The preflight refuses to publish unless CI is already green on this exact
# commit across all three platforms. v0.2.0 shipped half-populated because
# nothing checked that first.
#
# Version comes from app.zon. Options:
#   --publish              create the GitHub release and follow the runs
#   --notes-file <path>    use these release notes instead of --generate-notes
#   --skip-ci-check        publish even if CI is not green (emergencies only)
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo"

publish=false
skip_ci_check=false
notes_file=""

while [ $# -gt 0 ]; do
    case "$1" in
        --publish) publish=true ;;
        --skip-ci-check) skip_ci_check=true ;;
        --notes-file) shift; notes_file="${1:-}"; [ -n "$notes_file" ] || { echo "error: --notes-file needs a path" >&2; exit 1; } ;;
        *) echo "error: unknown option '$1'" >&2; exit 1 ;;
    esac
    shift
done

fail() { echo "error: $*" >&2; exit 1; }
ok()   { echo "  ok   $*"; }

command -v gh >/dev/null 2>&1 || fail "gh CLI not found"
gh auth status >/dev/null 2>&1 || fail "gh is not authenticated (gh auth login)"

version="$(sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' app.zon | head -1)"
[ -n "$version" ] || fail "could not read .version from app.zon"
tag="v$version"

echo "==> SUB/WAVE Desktop $version"
echo "==> preflight"

# --- the tag must point at what ships -----------------------------------
branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$branch" = "main" ] || fail "on branch '$branch'; releases are cut from main"
ok "on main"

git diff --quiet && git diff --cached --quiet || fail "uncommitted changes to tracked files; commit or stash them"
ok "working tree clean"

git fetch -q origin main
local_sha="$(git rev-parse HEAD)"
remote_sha="$(git rev-parse origin/main)"
[ "$local_sha" = "$remote_sha" ] || fail "main is out of sync with origin/main (local ${local_sha:0:7}, remote ${remote_sha:0:7})"
ok "in sync with origin/main"

if gh release view "$tag" >/dev/null 2>&1; then
    fail "release $tag already exists — bump .version in app.zon first (re-cutting a botched build is the only reason to reuse a tag, and that needs a manual gh release upload --clobber)"
fi
ok "$tag does not exist yet"

# --- the SDK patches must be present ------------------------------------
# CI installs the SDK fresh and applies them itself, so this is about the
# machine you are standing at telling you the truth about its own state.
if ./scripts/apply-sdk-patches.sh >/dev/null 2>&1; then
    ok "local SDK patches applied"
else
    echo "  warn local SDK is not fully patched (CI applies them itself, so this"
    echo "       does not affect the release; run ./scripts/apply-sdk-patches.sh"
    echo "       if you intend to build locally)"
fi

# --- CI must already be green on this commit ----------------------------
if $skip_ci_check; then
    echo "  warn skipping the CI check (--skip-ci-check)"
else
    run_json="$(gh run list --workflow ci.yml --branch main --limit 30 \
        --json headSha,status,conclusion,databaseId,url 2>/dev/null || echo '[]')"
    match="$(printf '%s' "$run_json" | jq -r --arg sha "$local_sha" \
        '[.[] | select(.headSha == $sha)] | .[0] // empty')"

    if [ -z "$match" ]; then
        fail "no CI run found for ${local_sha:0:7}. Push the commit and let CI finish, or pass --skip-ci-check"
    fi
    status="$(printf '%s' "$match" | jq -r .status)"
    conclusion="$(printf '%s' "$match" | jq -r .conclusion)"
    run_url="$(printf '%s' "$match" | jq -r .url)"

    case "$status:$conclusion" in
        completed:success) ok "CI green on ${local_sha:0:7}" ;;
        completed:*) fail "CI concluded '$conclusion' on ${local_sha:0:7} — $run_url" ;;
        *) fail "CI is still $status on ${local_sha:0:7} — wait for it, or pass --skip-ci-check ($run_url)" ;;
    esac
fi

if ! $publish; then
    echo
    echo "preflight passed. Publish with:"
    echo "  ./scripts/make-release.sh --publish"
    exit 0
fi

# --- publish -------------------------------------------------------------
echo "==> creating release $tag"
if [ -n "$notes_file" ]; then
    [ -f "$notes_file" ] || fail "notes file '$notes_file' not found"
    gh release create "$tag" --title "SUB/WAVE Desktop $version" --notes-file "$notes_file" --target main
else
    # --generate-notes is a placeholder: replace it with something a listener
    # would actually read (see the release skill for the shape).
    gh release create "$tag" --title "SUB/WAVE Desktop $version" --generate-notes --target main
fi

echo "==> following the release workflows"
workflows=(release-macos.yml release-windows.yml release-linux.yml)
sleep 20   # let the runs register against the release event

deadline=$((SECONDS + 2400))
while [ $SECONDS -lt $deadline ]; do
    pending=0
    line=""
    for wf in "${workflows[@]}"; do
        row="$(gh run list --workflow "$wf" --limit 1 --json status,conclusion \
            --jq '.[0] | "\(.status):\(.conclusion // "-")"' 2>/dev/null || echo "unknown:-")"
        case "$row" in completed:*) ;; *) pending=$((pending + 1)) ;; esac
        line="$line  ${wf%.yml}=${row}"
    done
    echo "   $line"
    [ "$pending" -eq 0 ] && break
    sleep 30
done

echo "==> assets on $tag"
gh release view "$tag" --json assets --jq '.assets[] | "  \(.name)  \(.size) bytes"'
gh release view "$tag" --json url --jq .url

count="$(gh release view "$tag" --json assets --jq '.assets | length')"
if [ "$count" -lt 3 ]; then
    echo
    echo "warning: only $count/3 assets uploaded. Check the runs above and re-run a"
    echo "failed leg with: gh workflow run release-<os>.yml -f tag=$tag" >&2
    exit 1
fi
echo "all three assets present"
