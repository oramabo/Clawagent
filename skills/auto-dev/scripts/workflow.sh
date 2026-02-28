#!/usr/bin/env bash
# workflow.sh — Orchestrator and utility commands for the auto-dev skill
#
# Provides preflight checks, branch management, and status reporting.
#
# Commands:
#   preflight                   Verify all required tools and credentials
#   status                      Show active auto-dev sessions and branches
#   list-tasks                  Formatted table of assigned Jira tasks
#   setup-branch <KEY> [base]   Create a working branch for a task
#   cleanup <KEY>               Remove a completed auto-dev branch
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JIRA="${SCRIPT_DIR}/jira.sh"
CLAUDE_TERM="${SCRIPT_DIR}/claude_terminal.sh"
NOTIFY="${SCRIPT_DIR}/notify.sh"
GITHUB="${SCRIPT_DIR}/github.sh"

# --- Commands ---

cmd_preflight() {
  echo "=== Auto-Dev Preflight Check ==="
  local all_ok=true

  # Check required binaries
  for bin in curl jq git claude tmux; do
    if command -v "$bin" &>/dev/null; then
      local version
      version=$("$bin" --version 2>/dev/null | head -1 || echo "installed")
      echo "  ✓ ${bin}: ${version}"
    else
      echo "  ✗ ${bin}: NOT FOUND"
      all_ok=false
    fi
  done

  # gh is optional (can use GITHUB_TOKEN instead)
  if command -v gh &>/dev/null; then
    local version
    version=$(gh --version 2>/dev/null | head -1 || echo "installed")
    echo "  ✓ gh: ${version}"
  else
    echo "  ⚠ gh: NOT FOUND (optional — GITHUB_TOKEN can be used instead)"
  fi

  echo ""

  # Check Jira credentials
  echo "--- Jira ---"
  if [[ -n "${JIRA_BASE_URL:-}" && -n "${JIRA_EMAIL:-}" && -n "${JIRA_API_TOKEN:-}" ]]; then
    bash "$JIRA" healthcheck 2>&1 | sed 's/^/  /'
  else
    echo "  ✗ Jira credentials not set"
    [[ -z "${JIRA_BASE_URL:-}" ]] && echo "    Missing: JIRA_BASE_URL"
    [[ -z "${JIRA_EMAIL:-}" ]] && echo "    Missing: JIRA_EMAIL"
    [[ -z "${JIRA_API_TOKEN:-}" ]] && echo "    Missing: JIRA_API_TOKEN"
    all_ok=false
  fi

  echo ""

  # Check project key
  echo "--- Project ---"
  if [[ -n "${JIRA_PROJECT_KEY:-}" ]]; then
    echo "  ✓ JIRA_PROJECT_KEY: ${JIRA_PROJECT_KEY}"
  else
    echo "  ⚠ JIRA_PROJECT_KEY not set (will use all projects)"
  fi

  echo ""

  # Check git
  echo "--- Git ---"
  if git rev-parse --git-dir &>/dev/null; then
    local branch remote_url
    branch=$(git branch --show-current 2>/dev/null || echo "detached")
    remote_url=$(git remote get-url origin 2>/dev/null || echo "no remote")
    echo "  ✓ In git repo on branch: ${branch}"
    echo "  ✓ Remote: ${remote_url}"
  else
    echo "  ✗ Not in a git repository"
    all_ok=false
  fi

  echo ""

  # Check GitHub credentials (gh CLI or API token)
  echo "--- GitHub ---"
  bash "$GITHUB" healthcheck 2>&1 | sed 's/^/  /' || all_ok=false

  echo ""
  echo "=== Preflight $(${all_ok} && echo "PASSED" || echo "FAILED — fix issues above") ==="

  $all_ok
}

cmd_status() {
  echo "=== Auto-Dev Status ==="

  echo ""
  echo "Active Claude Code sessions:"
  bash "$CLAUDE_TERM" list 2>/dev/null | sed 's/^/  /'

  echo ""
  echo "Auto-dev branches:"
  git branch --list 'feat/*' 2>/dev/null | sed 's/^/  /' || echo "  (none)"

  echo ""
  echo "Current branch: $(git branch --show-current 2>/dev/null || echo 'not in git repo')"

  echo ""
  echo "Uncommitted changes:"
  git status --short 2>/dev/null | head -20 | sed 's/^/  /' || echo "  (not in git repo)"
  local total_changes
  total_changes=$(git status --short 2>/dev/null | wc -l || echo 0)
  if [[ "$total_changes" -gt 20 ]]; then
    echo "  ... and $((total_changes - 20)) more"
  fi
}

cmd_list_tasks() {
  echo "=== Assigned Jira Tasks ==="
  echo ""

  local raw
  raw=$(bash "$JIRA" my-tasks 2>/dev/null)

  local count
  count=$(echo "$raw" | jq -r '.total // 0')

  if [[ "$count" -eq 0 ]]; then
    echo "No tasks assigned. Queue is empty."
    return 0
  fi

  # Pretty-print as a table
  printf "%-12s %-10s %-12s %s\n" "KEY" "PRIORITY" "STATUS" "SUMMARY"
  printf "%-12s %-10s %-12s %s\n" "---" "--------" "------" "-------"
  echo "$raw" | jq -r '.issues[] | [
    .key,
    (.fields.priority.name // "None"),
    (.fields.status.name // "Unknown"),
    (.fields.summary // "No summary")
  ] | @tsv' | while IFS=$'\t' read -r key priority status summary; do
    printf "%-12s %-10s %-12s %s\n" "$key" "$priority" "$status" "${summary:0:60}"
  done

  echo ""
  echo "Total: ${count} task(s)"
}

cmd_setup_branch() {
  local issue_key="$1"
  local base_branch="${2:-main}"

  # Slugify the issue key for the branch name
  local branch_name="feat/${issue_key}"

  # Check if branch already exists
  if git show-ref --verify --quiet "refs/heads/${branch_name}" 2>/dev/null; then
    echo "WARN: Branch '${branch_name}' already exists. Checking it out."
    git checkout "$branch_name"
    return 0
  fi

  # Fetch the base branch
  git fetch origin "$base_branch" 2>/dev/null || {
    # Try master if main doesn't exist
    base_branch="master"
    git fetch origin "$base_branch" 2>/dev/null || {
      echo "ERROR: Could not fetch base branch (tried main and master)" >&2
      return 1
    }
  }

  git checkout -b "$branch_name" "origin/${base_branch}"
  echo "OK: Created branch '${branch_name}' from 'origin/${base_branch}'"
}

cmd_cleanup() {
  local issue_key="$1"
  local branch_name="feat/${issue_key}"

  # Switch to main first
  git checkout main 2>/dev/null || git checkout master 2>/dev/null || {
    echo "ERROR: Could not checkout main/master" >&2
    return 1
  }

  # Delete the feature branch
  git branch -d "$branch_name" 2>/dev/null || {
    echo "WARN: Branch '${branch_name}' has unmerged changes. Use 'git branch -D' to force delete." >&2
    return 1
  }

  echo "OK: Branch '${branch_name}' deleted"
}

cmd_cron() {
  local action="${1:-status}"
  shift 2>/dev/null || true
  bash "${SCRIPT_DIR}/cron.sh" "$action" "$@"
}

# --- Router ---

case "${1:-help}" in
  preflight)    cmd_preflight ;;
  status)       cmd_status ;;
  list-tasks)   cmd_list_tasks ;;
  setup-branch) cmd_setup_branch "$2" "${3:-main}" ;;
  cleanup)      cmd_cleanup "$2" ;;
  cron)         shift; cmd_cron "$@" ;;
  help|*)
    cat <<'USAGE'
Usage: workflow.sh <command> [args]

Commands:
  preflight                   Verify all tools and credentials
  status                      Show active sessions and branches
  list-tasks                  Formatted table of assigned Jira tasks
  setup-branch <KEY> [base]   Create feat/<KEY> branch from base (default: main)
  cleanup <KEY>               Delete feat/<KEY> branch after merge
  cron <action> [args]        Manage cron daemon (start|stop|status|run-once|...)

Examples:
  workflow.sh preflight
  workflow.sh list-tasks
  workflow.sh setup-branch PROJ-123
  workflow.sh cleanup PROJ-123
  workflow.sh cron start
  workflow.sh cron status
  workflow.sh cron run-once autonomy
USAGE
    ;;
esac
