#!/bin/sh
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/release.sh <version>
  version: 1.2.3 (do not include leading "v")
USAGE
}

if [ "${1-}" = "" ]; then
  usage
  exit 1
fi

VERSION="$1"
TAG="v$VERSION"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Not inside a git repo."
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree is dirty. Commit or stash changes first."
  exit 1
fi

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "Tag $TAG already exists."
  exit 1
fi

git tag -a "$TAG" -m "Release $TAG"
git push origin "$TAG"

echo "Created and pushed $TAG."
