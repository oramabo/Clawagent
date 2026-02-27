#!/usr/bin/env bash
# github.sh — GitHub wrapper for the auto-dev skill
#
# Supports two modes:
#   1. GitHub CLI (gh) — if `gh` is installed and authenticated
#   2. GitHub API token — if GITHUB_TOKEN is set (no gh required)
#
# Environment variables:
#   GITHUB_TOKEN   - Personal access token (required if gh is not available)
#   GITHUB_OWNER   - Repository owner (auto-detected from git remote if unset)
#   GITHUB_REPO    - Repository name (auto-detected from git remote if unset)
set -euo pipefail

# --- Detect mode ---

_use_gh() {
  command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1
}

_require_github() {
  if ! _use_gh && [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo "ERROR: No GitHub credentials found." >&2
    echo "  Either install and authenticate gh (gh auth login)" >&2
    echo "  or set GITHUB_TOKEN to a personal access token." >&2
    return 1
  fi
}

# --- Repo detection ---

_detect_owner_repo() {
  if [[ -n "${GITHUB_OWNER:-}" && -n "${GITHUB_REPO:-}" ]]; then
    return 0
  fi

  local remote_url
  remote_url=$(git remote get-url origin 2>/dev/null || true)

  if [[ -z "$remote_url" ]]; then
    echo "ERROR: No git remote 'origin' found and GITHUB_OWNER/GITHUB_REPO not set." >&2
    return 1
  fi

  # Extract owner/repo from SSH or HTTPS URL
  local owner_repo
  owner_repo=$(echo "$remote_url" | sed -E 's#^.+github\.com[:/]##' | sed 's/\.git$//')

  GITHUB_OWNER="${GITHUB_OWNER:-$(echo "$owner_repo" | cut -d/ -f1)}"
  GITHUB_REPO="${GITHUB_REPO:-$(echo "$owner_repo" | cut -d/ -f2)}"
}

# --- Core API helper ---

_curl_github() {
  local method="$1"
  local endpoint="$2"
  shift 2

  local response http_code
  response=$(curl -s -w "\n%{http_code}" \
    -X "$method" \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com${endpoint}" \
    "$@")

  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" -ge 400 ]]; then
    echo "ERROR: GitHub API returned HTTP ${http_code}" >&2
    echo "$body" | jq '.' 2>/dev/null || echo "$body" >&2
    return 1
  fi

  echo "$body"
}

# --- Commands ---

cmd_healthcheck() {
  _require_github || return 1

  if _use_gh; then
    echo "OK: Using GitHub CLI (gh)"
    gh auth status 2>&1 | head -3 | sed 's/^/  /'
  else
    _detect_owner_repo
    local result
    result=$(_curl_github GET "/user") || {
      echo "FAIL: Could not authenticate with GITHUB_TOKEN." >&2
      return 1
    }
    local login
    login=$(echo "$result" | jq -r '.login // "unknown"')
    echo "OK: Authenticated via API token as ${login}"
  fi
}

cmd_create_pr() {
  local title="$1"
  local body="$2"
  local head="${3:-$(git branch --show-current)}"
  local base="${4:-main}"

  _require_github || return 1

  if _use_gh; then
    gh pr create --title "$title" --body "$body" --head "$head" --base "$base" 2>&1
  else
    _detect_owner_repo

    local payload
    payload=$(jq -n \
      --arg title "$title" \
      --arg body "$body" \
      --arg head "$head" \
      --arg base "$base" \
      '{title: $title, body: $body, head: $head, base: $base}')

    local result
    result=$(_curl_github POST "/repos/${GITHUB_OWNER}/${GITHUB_REPO}/pulls" -d "$payload")

    local pr_url
    pr_url=$(echo "$result" | jq -r '.html_url // empty')

    if [[ -n "$pr_url" ]]; then
      echo "$pr_url"
    else
      echo "$result" | jq '.'
      return 1
    fi
  fi
}

cmd_list_prs() {
  local state="${1:-open}"

  _require_github || return 1

  if _use_gh; then
    gh pr list --state "$state"
  else
    _detect_owner_repo
    local result
    result=$(_curl_github GET "/repos/${GITHUB_OWNER}/${GITHUB_REPO}/pulls?state=${state}")
    echo "$result" | jq -r '.[] | "#\(.number)\t\(.state)\t\(.title)\t\(.html_url)"'
  fi
}

cmd_get_pr() {
  local pr_number="$1"

  _require_github || return 1

  if _use_gh; then
    gh pr view "$pr_number"
  else
    _detect_owner_repo
    _curl_github GET "/repos/${GITHUB_OWNER}/${GITHUB_REPO}/pulls/${pr_number}"
  fi
}

# --- Router ---

case "${1:-help}" in
  healthcheck)  cmd_healthcheck ;;
  create-pr)    cmd_create_pr "$2" "$3" "${4:-}" "${5:-main}" ;;
  list-prs)     cmd_list_prs "${2:-open}" ;;
  get-pr)       cmd_get_pr "$2" ;;
  help|*)
    cat <<'USAGE'
Usage: github.sh <command> [args]

Commands:
  healthcheck                              Verify GitHub credentials
  create-pr <title> <body> [head] [base]   Create a pull request
  list-prs [state]                         List pull requests (default: open)
  get-pr <number>                          Get PR details

Modes:
  - If `gh` CLI is installed and authenticated, it is used automatically
  - Otherwise, set GITHUB_TOKEN for direct API access

Environment:
  GITHUB_TOKEN   Personal access token (required if gh is not available)
  GITHUB_OWNER   Repository owner (auto-detected from git remote)
  GITHUB_REPO    Repository name (auto-detected from git remote)

Examples:
  github.sh healthcheck
  github.sh create-pr "feat(PROJ-123): Add login" "## Summary\n- Added login form" feat/PROJ-123 main
  github.sh list-prs open
  github.sh get-pr 42
USAGE
    ;;
esac
