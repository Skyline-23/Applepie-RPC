#!/usr/bin/env bash
set -euo pipefail

current_tag="${1:-${GITHUB_REF_NAME:-}}"
if [[ -z "${current_tag}" ]]; then
  echo "usage: $(basename "$0") <tag>" >&2
  exit 2
fi

repo="${GITHUB_REPOSITORY:-}"
compare_url=""
if [[ -n "${repo}" ]]; then
  compare_url="https://github.com/${repo}/compare"
fi

# Prefer a tag that is actually reachable in history from the current tag.
prev_tag="$(git describe --tags --abbrev=0 "${current_tag}^" 2>/dev/null || true)"
if [[ -z "${prev_tag}" ]]; then
  # Fallback: version-sort tags and pick the next-most-recent.
  prev_tag="$(git tag --list 'v*' --sort=-v:refname | grep -v "^${current_tag}$" | head -n 1 || true)"
fi

echo "## Changes"

if [[ -n "${prev_tag}" && -n "${compare_url}" ]]; then
  echo
  echo "Full Changelog: ${compare_url}/${prev_tag}...${current_tag}"
fi

echo

if [[ -n "${prev_tag}" ]]; then
  range="${prev_tag}..${current_tag}"
  revs=( $(git rev-list --no-merges "${range}") )
else
  # First tag in history, cap output to avoid dumping the whole repo history.
  revs=( $(git rev-list --no-merges --max-count=50 "${current_tag}") )
fi

if [[ ${#revs[@]} -eq 0 ]]; then
  echo "- No changes detected."
  exit 0
fi

for sha in "${revs[@]}"; do
  subject="$(git log -1 --format=%s "${sha}")"
  echo "- ${subject}"

  # Pull only bullet lines from the commit body to keep the notes readable.
  git log -1 --format=%b "${sha}" \
    | sed -nE 's/^[[:space:]]*-[[:space:]]+/  - /p'
done

