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

# Exclude commits that only touch CI/automation paths.
# Override with RELEASE_NOTES_EXCLUDE_REGEX to tweak (bash regex syntax).
exclude_regex="${RELEASE_NOTES_EXCLUDE_REGEX:-^(\\.github/|scripts/|Casks/)}"

should_include_commit() {
  local sha="$1"
  local files
  files="$(git diff-tree --no-commit-id --name-only -r "${sha}" 2>/dev/null || true)"
  [[ -n "${files}" ]] || return 1

  while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    if ! [[ "${f}" =~ ${exclude_regex} ]]; then
      return 0
    fi
  done <<<"${files}"

  return 1
}

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

printed_any=0
for sha in "${revs[@]}"; do
  if ! should_include_commit "${sha}"; then
    continue
  fi

  subject="$(git log -1 --format=%s "${sha}")"
  echo "- ${subject}"
  printed_any=1

  # Pull only bullet lines from the commit body to keep the notes readable.
  git log -1 --format=%b "${sha}" \
    | sed -nE 's/^[[:space:]]*-[[:space:]]+/  - /p'
done

if [[ "${printed_any}" -eq 0 ]]; then
  echo "- No user-facing changes."
fi
