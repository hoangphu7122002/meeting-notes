#!/usr/bin/env bash
# Print the app version. Single source of truth: git tags vX.Y.Z on master (no VERSION file, no bump commits).
#   HEAD tagged vX.Y.Z   -> X.Y.Z                      (a release)
#   otherwise            -> latest reachable vX.Y.Z    (untagged master build; 0.0.0 before the first tag)
# --describe adds the distance for untagged commits, e.g. 0.2.0-edge.5+g1a2b3c4 (artifact names only; Info.plist
# always gets plain X.Y.Z, CFBundleVersion is the build timestamp).
#
# Usage: scripts/version.sh [--describe]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESCRIBE=0
case "${1:-}" in
  "") ;;
  --describe) DESCRIBE=1 ;;
  -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
  *) echo "unknown argument: $1 (see --help)" >&2; exit 64 ;;
esac

MATCH='v[0-9]*.[0-9]*.[0-9]*'
is_semver() { [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

exact="$(git -C "$ROOT" describe --tags --exact-match --match "$MATCH" HEAD 2>/dev/null || true)"
if is_semver "$exact"; then
  echo "${exact#v}"
  exit 0
fi
last="$(git -C "$ROOT" describe --tags --abbrev=0 --match "$MATCH" HEAD 2>/dev/null || true)"
is_semver "$last" || last="v0.0.0"
if [[ "$DESCRIBE" -eq 0 ]]; then
  echo "${last#v}"
  exit 0
fi
if [[ "$last" == v0.0.0 ]]; then
  count="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"
else
  count="$(git -C "$ROOT" rev-list --count "$last..HEAD" 2>/dev/null || echo 0)"
fi
sha="$(git -C "$ROOT" rev-parse --short=7 HEAD 2>/dev/null || echo unknown)"
echo "${last#v}-edge.$count+g$sha"
