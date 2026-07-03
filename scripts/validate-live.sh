#!/usr/bin/env bash
set -euo pipefail

missing=()

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    missing+=("$name")
  fi
}

require_env GITPONT_LIVE_GITHUB_TOKEN
require_env GITPONT_LIVE_GITHUB_WRITE_REPO
require_env GITPONT_LIVE_GITLAB_TOKEN
require_env GITPONT_LIVE_GITLAB_WRITE_REPO
require_env GITPONT_LIVE_FORGEJO_TOKEN
require_env GITPONT_LIVE_FORGEJO_WRITE_REPO

if (( ${#missing[@]} > 0 )); then
  printf 'Missing required live validation environment variables:\n' >&2
  printf '  %s\n' "${missing[@]}" >&2
  printf '\nUse only dedicated disposable test repositories. Optional base-ref variables:\n' >&2
  printf '  GITPONT_LIVE_GITHUB_WRITE_BASE_REF\n' >&2
  printf '  GITPONT_LIVE_GITLAB_WRITE_BASE_REF\n' >&2
  printf '  GITPONT_LIVE_FORGEJO_WRITE_BASE_REF\n' >&2
  exit 2
fi

swift test --package-path libs/swift --filter LiveIntegrationTests
