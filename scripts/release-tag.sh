#!/usr/bin/env bash
# Cut a release (trunk-based): check that master is clean, pushed and green, then create the annotated tag vX.Y.Z
# on master HEAD and print the push command. It never pushes: pushing the tag starts .github/workflows/release.yml,
# which builds the dmg and publishes the GitHub Release (docs/release.md).
#
# Usage: scripts/release-tag.sh X.Y.Z        (or: make release-tag VERSION=X.Y.Z)
# Env:   LOCAL_CI=1  run "make ci" here instead of requiring a green GitHub "ci" run for HEAD (no gh needed)
#        REMOTE      git remote (default origin)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE="${REMOTE:-origin}"
BRANCH="master"
VERSION="${1:-}"
VERSION="${VERSION#v}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: make release-tag VERSION=X.Y.Z (got '${1:-}')"
TAG="v$VERSION"
cd "$ROOT"

branch="$(git rev-parse --abbrev-ref HEAD)"
[[ "$branch" == "$BRANCH" ]] || die "on '$branch': releases are tagged on $BRANCH only (trunk-based; hotfix = fix on $BRANCH + patch tag)"
[[ -z "$(git status --porcelain)" ]] || die "the working tree has uncommitted changes"
git fetch --quiet --tags "$REMOTE" "$BRANCH" || die "cannot fetch $REMOTE/$BRANCH"
head="$(git rev-parse HEAD)"
[[ "$head" == "$(git rev-parse "$REMOTE/$BRANCH")" ]] \
  || die "HEAD differs from $REMOTE/$BRANCH: push or pull first (the tag must point at a commit CI has tested)"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then die "tag $TAG already exists"; fi

highest="$(git tag -l 'v[0-9]*' | { grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true; } | sed 's/^v//' \
            | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)"
if [[ -n "$highest" ]]; then
  top="$(printf '%s\n%s\n' "$highest" "$VERSION" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)"
  [[ "$top" == "$VERSION" && "$VERSION" != "$highest" ]] || die "$TAG is not newer than the latest release v$highest"
fi

short="$(git rev-parse --short HEAD)"
if [[ "${LOCAL_CI:-0}" == 1 ]]; then
  echo "==> make ci (LOCAL_CI=1)"
  make -C "$ROOT" ci
else
  command -v gh >/dev/null 2>&1 || die "gh not found: install it (brew install gh) or run with LOCAL_CI=1"
  state="$(gh run list --workflow ci.yml --commit "$head" --event push --limit 1 \
            --json status,conclusion --jq '.[0] | "\(.status) \(.conclusion)"' 2>/dev/null)" \
    || die "cannot query GitHub CI (gh auth login?), or run with LOCAL_CI=1"
  [[ "$state" == "completed success" ]] \
    || die "CI for $short on $BRANCH is '${state:-not found}': wait until it is green (gh run list --workflow ci.yml)"
  echo "==> CI green for $short"
fi

git tag -a "$TAG" -m "Meeting Notes $VERSION"
cat <<MSG
Created annotated tag $TAG on $short ($BRANCH). Nothing was pushed.
To release, push the tag; GitHub Actions (release.yml) builds the dmg and publishes the Release:

  git push $REMOTE $TAG

Undo before pushing: git tag -d $TAG
MSG
