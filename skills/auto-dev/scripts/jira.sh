#!/usr/bin/env bash
# jira.sh — Jira Cloud REST API v3 wrapper for the auto-dev skill
#
# Required environment variables:
#   JIRA_BASE_URL    - Your Jira Cloud URL (e.g., https://yoursite.atlassian.net)
#   JIRA_EMAIL       - Your Jira account email
#   JIRA_API_TOKEN   - API token from id.atlassian.com/manage-profile/security/api-tokens
#   JIRA_PROJECT_KEY - Default project key (e.g., PROJ)
#
# All output is JSON piped through jq for clean parsing.
# Exit codes: 0 = success, 1 = error (with message on stderr)
set -euo pipefail

# Validate required env vars on source
: "${JIRA_BASE_URL:?Set JIRA_BASE_URL to your Jira Cloud URL (e.g., https://yoursite.atlassian.net)}"
: "${JIRA_EMAIL:?Set JIRA_EMAIL to your Jira account email}"
: "${JIRA_API_TOKEN:?Set JIRA_API_TOKEN from id.atlassian.com/manage-profile/security/api-tokens}"

JIRA_API="${JIRA_BASE_URL}/rest/api/3"

# --- Core HTTP helper ---

_curl_jira() {
  local method="$1"
  local endpoint="$2"
  shift 2

  local response http_code
  response=$(curl -s -w "\n%{http_code}" \
    -X "$method" \
    -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    "${JIRA_API}${endpoint}" \
    "$@")

  # Split response body and HTTP status code
  http_code=$(echo "$response" | tail -1)
  local body
  body=$(echo "$response" | sed '$d')

  if [[ "$http_code" -ge 400 ]]; then
    echo "ERROR: Jira API returned HTTP ${http_code}" >&2
    echo "$body" | jq '.' 2>/dev/null || echo "$body" >&2
    return 1
  fi

  echo "$body"
}

# --- Commands ---

cmd_healthcheck() {
  local result
  result=$(_curl_jira GET "/myself") || {
    echo "FAIL: Could not authenticate. Check JIRA_BASE_URL, JIRA_EMAIL, JIRA_API_TOKEN." >&2
    return 1
  }

  local display_name
  display_name=$(echo "$result" | jq -r '.displayName // "unknown"')
  echo "OK: Authenticated as ${display_name}"
}

cmd_my_tasks() {
  local max_results="${1:-20}"
  local project="${JIRA_PROJECT_KEY:-}"

  local jql='assignee = currentUser() AND status IN ("To Do", "Open", "Selected for Development", "Backlog") ORDER BY priority DESC, created ASC'

  if [[ -n "$project" ]]; then
    jql="project = ${project} AND ${jql}"
  fi

  local payload
  payload=$(jq -n \
    --arg jql "$jql" \
    --argjson max "$max_results" \
    '{jql: $jql, maxResults: $max, fields: ["summary", "status", "priority", "issuetype", "description"]}')

  _curl_jira POST "/search/jql" -d "$payload"
}

cmd_get() {
  local issue_key="$1"
  _curl_jira GET "/issue/${issue_key}?fields=summary,status,priority,description,comment,issuetype,assignee,labels,parent,subtasks,fixVersions"
}

cmd_search() {
  local jql="$1"
  local max_results="${2:-10}"

  local payload
  payload=$(jq -n \
    --arg jql "$jql" \
    --argjson max "$max_results" \
    '{jql: $jql, maxResults: $max, fields: ["summary", "status", "priority"]}')

  _curl_jira POST "/search/jql" -d "$payload"
}

cmd_transition() {
  local issue_key="$1"
  local target_status="$2"

  # Get available transitions
  local transitions
  transitions=$(_curl_jira GET "/issue/${issue_key}/transitions")

  # Find matching transition ID (case-insensitive)
  local transition_id
  transition_id=$(echo "$transitions" | jq -r \
    --arg target "$target_status" \
    '.transitions[] | select(.name | ascii_downcase == ($target | ascii_downcase)) | .id' \
    | head -1)

  if [[ -z "$transition_id" || "$transition_id" == "null" ]]; then
    echo "ERROR: No transition to '${target_status}' available for ${issue_key}." >&2
    echo "Available transitions:" >&2
    echo "$transitions" | jq -r '.transitions[] | "  - \(.name) (id: \(.id))"' >&2
    return 1
  fi

  _curl_jira POST "/issue/${issue_key}/transitions" \
    -d "$(jq -n --arg id "$transition_id" '{transition: {id: $id}}')"

  echo "OK: ${issue_key} transitioned to '${target_status}'"
}

cmd_transitions() {
  local issue_key="$1"
  _curl_jira GET "/issue/${issue_key}/transitions" \
    | jq -r '.transitions[] | "\(.id)\t\(.name)"'
}

cmd_comment() {
  local issue_key="$1"
  local text="$2"

  # Jira Cloud v3 uses Atlassian Document Format (ADF) for comments
  local payload
  payload=$(jq -n --arg text "$text" '{
    body: {
      type: "doc",
      version: 1,
      content: [{
        type: "paragraph",
        content: [{type: "text", text: $text}]
      }]
    }
  }')

  _curl_jira POST "/issue/${issue_key}/comment" -d "$payload" | jq '{id: .id, created: .created}'
  echo "OK: Comment added to ${issue_key}"
}

cmd_create() {
  local summary="$1"
  local description="${2:-}"
  local issue_type="${3:-Task}"
  local parent_key="${4:-}"
  local project="${JIRA_PROJECT_KEY:?JIRA_PROJECT_KEY is required for issue creation}"

  local payload
  payload=$(jq -n \
    --arg proj "$project" \
    --arg summary "$summary" \
    --arg type "$issue_type" \
    --arg desc "$description" \
    --arg parent "$parent_key" \
    '{
      fields: {
        project: {key: $proj},
        summary: $summary,
        issuetype: {name: $type},
        description: {
          type: "doc",
          version: 1,
          content: [{
            type: "paragraph",
            content: [{type: "text", text: $desc}]
          }]
        }
      }
    }
    | if $parent != "" then .fields.parent = {key: $parent} else . end')

  local result
  result=$(_curl_jira POST "/issue" -d "$payload")
  echo "$result" | jq '{key: .key, id: .id, self: .self}'
}

cmd_link() {
  local issue_key="$1"
  echo "${JIRA_BASE_URL}/browse/${issue_key}"
}

# --- Router ---

case "${1:-help}" in
  healthcheck)   cmd_healthcheck ;;
  my-tasks)      cmd_my_tasks "${2:-20}" ;;
  get)           cmd_get "$2" ;;
  search)        cmd_search "$2" "${3:-10}" ;;
  transition)    cmd_transition "$2" "$3" ;;
  transitions)   cmd_transitions "$2" ;;
  comment)       cmd_comment "$2" "$3" ;;
  create)        cmd_create "$2" "${3:-}" "${4:-Task}" "${5:-}" ;;
  link)          cmd_link "$2" ;;
  help|*)
    cat <<'USAGE'
Usage: jira.sh <command> [args]

Commands:
  healthcheck                       Verify Jira credentials
  my-tasks [max]                    Fetch assigned open tasks (default: 20)
  get <issue-key>                   Get full issue details
  search <jql> [max]                Search with JQL query
  transition <key> <status>         Change issue status (e.g., "In Progress")
  transitions <key>                 List available status transitions
  comment <key> <text>              Add a comment to an issue
  create <summary> [desc] [type] [parent]  Create a new issue
  link <key>                        Get browser URL for an issue

Environment:
  JIRA_BASE_URL      https://yoursite.atlassian.net
  JIRA_EMAIL         Your Jira email
  JIRA_API_TOKEN     API token
  JIRA_PROJECT_KEY   Default project key

Examples:
  jira.sh healthcheck
  jira.sh my-tasks
  jira.sh get PROJ-123
  jira.sh transition PROJ-123 "In Progress"
  jira.sh comment PROJ-123 "PR: https://github.com/org/repo/pull/42"
  jira.sh create "Fix login bug" "Login form throws 500 on empty email" "Bug"
USAGE
    ;;
esac
