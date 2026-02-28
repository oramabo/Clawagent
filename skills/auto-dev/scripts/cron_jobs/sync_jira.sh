#!/usr/bin/env bash
# sync_jira.sh — Poll Jira for changes and notify on updates
#
# Detects:
#   - New tasks assigned to the user
#   - Status changes on known tasks
#   - Priority changes (especially escalations)
#   - New comments on tasks with active sessions
#   - Tasks removed from assignment
#
# Runs from both the daemon and system crontab.
#
# Expected env (set by cron.sh):
#   STATE_DIR, SCRIPT_DIR, JIRA_CMD, NOTIFY, CLAUDE_TERM
set -euo pipefail

JIRA_DIR="${STATE_DIR}/jira"
mkdir -p "$JIRA_DIR"

KNOWN_FILE="${JIRA_DIR}/known_tasks.json"
COMMENTS_FILE="${JIRA_DIR}/last_comments.json"
FAIL_COUNT_FILE="${JIRA_DIR}/fail_count"

# --- Fetch current tasks ---

current_raw=$(bash "$JIRA_CMD" my-tasks 2>/dev/null) || {
  # Track consecutive failures
  fail_count=0
  [[ -f "$FAIL_COUNT_FILE" ]] && fail_count=$(cat "$FAIL_COUNT_FILE")
  fail_count=$((fail_count + 1))
  echo "$fail_count" > "$FAIL_COUNT_FILE"

  echo "JIRA_SYNC: Fetch failed (${fail_count} consecutive)"

  if (( fail_count >= 3 )); then
    bash "$NOTIFY" jira-update "SYSTEM" "Jira unreachable for ${fail_count} consecutive polls. Check credentials or network." \
      2>/dev/null || true
  fi
  exit 0
}

# Reset fail counter on success
echo "0" > "$FAIL_COUNT_FILE"

# Parse current tasks into a comparable format
# Each line: KEY|STATUS|PRIORITY|SUMMARY
current_tasks=$(echo "$current_raw" | jq -r '.issues[]? | [
  .key,
  (.fields.status.name // "Unknown"),
  (.fields.priority.name // "None"),
  (.fields.summary // "No summary")
] | join("|")' 2>/dev/null || true)

# --- Load previous snapshot ---

known_tasks=""
if [[ -f "$KNOWN_FILE" ]] && [[ -s "$KNOWN_FILE" ]]; then
  known_tasks=$(jq -r '.issues[]? | [
    .key,
    (.fields.status.name // "Unknown"),
    (.fields.priority.name // "None"),
    (.fields.summary // "No summary")
  ] | join("|")' < "$KNOWN_FILE" 2>/dev/null || true)
fi

# --- Diff: detect changes ---

notify_on="$CRON_JOB_JIRA_NOTIFY_ON"

# Build lookup maps (key -> full line)
declare -A current_map known_map
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  k=$(echo "$line" | cut -d'|' -f1)
  current_map["$k"]="$line"
done <<< "$current_tasks"

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  k=$(echo "$line" | cut -d'|' -f1)
  known_map["$k"]="$line"
done <<< "$known_tasks"

# Detect new tasks
if [[ "$notify_on" == *"new_task"* ]]; then
  for key in "${!current_map[@]}"; do
    if [[ -z "${known_map[$key]:-}" ]]; then
      summary=$(echo "${current_map[$key]}" | cut -d'|' -f4)
      priority=$(echo "${current_map[$key]}" | cut -d'|' -f3)
      echo "JIRA_SYNC: New task assigned: ${key} (${priority})"
      bash "$NOTIFY" jira-new "$key" "${summary}" 2>/dev/null || true
    fi
  done
fi

# Detect changes on existing tasks
for key in "${!current_map[@]}"; do
  [[ -z "${known_map[$key]:-}" ]] && continue  # New task, already handled

  old_line="${known_map[$key]}"
  new_line="${current_map[$key]}"

  old_status=$(echo "$old_line" | cut -d'|' -f2)
  new_status=$(echo "$new_line" | cut -d'|' -f2)
  old_priority=$(echo "$old_line" | cut -d'|' -f3)
  new_priority=$(echo "$new_line" | cut -d'|' -f3)

  # Status change
  if [[ "$notify_on" == *"status_change"* ]] && [[ "$old_status" != "$new_status" ]]; then
    echo "JIRA_SYNC: Status change on ${key}: ${old_status} → ${new_status}"
    bash "$NOTIFY" jira-update "$key" "Status changed: ${old_status} → ${new_status}" 2>/dev/null || true
  fi

  # Priority change
  if [[ "$notify_on" == *"priority_change"* ]] && [[ "$old_priority" != "$new_priority" ]]; then
    echo "JIRA_SYNC: Priority change on ${key}: ${old_priority} → ${new_priority}"
    bash "$NOTIFY" jira-update "$key" "Priority changed: ${old_priority} → ${new_priority}" 2>/dev/null || true
  fi
done

# Detect removed tasks (were assigned, now gone)
for key in "${!known_map[@]}"; do
  if [[ -z "${current_map[$key]:-}" ]]; then
    summary=$(echo "${known_map[$key]}" | cut -d'|' -f4)
    echo "JIRA_SYNC: Task removed from assignment: ${key}"

    # Only notify if there's an active session for this task
    active_sessions=$(bash "$CLAUDE_TERM" list 2>/dev/null || true)
    if echo "$active_sessions" | grep -q "^${key}$"; then
      bash "$NOTIFY" jira-update "$key" "Task unassigned while session is active. Check if work should continue." 2>/dev/null || true
    fi
  fi
done

# --- Check for new comments on active sessions ---

if [[ "$notify_on" == *"new_comment"* ]]; then
  active_sessions=$(bash "$CLAUDE_TERM" list 2>/dev/null || true)

  if [[ "$active_sessions" != "(no active sessions)" ]] && [[ -n "$active_sessions" ]]; then
    # Load known comment IDs
    declare -A known_comments
    if [[ -f "$COMMENTS_FILE" ]] && [[ -s "$COMMENTS_FILE" ]]; then
      while IFS='=' read -r k v; do
        known_comments["$k"]="$v"
      done < "$COMMENTS_FILE"
    fi

    # Check each active session's task for new comments
    while IFS= read -r key; do
      [[ -z "$key" ]] && continue

      task_data=$(bash "$JIRA_CMD" get "$key" 2>/dev/null || true)
      [[ -z "$task_data" ]] && continue

      latest_comment_id=$(echo "$task_data" | jq -r '.fields.comment.comments[-1].id // "none"' 2>/dev/null || echo "none")
      latest_comment_author=$(echo "$task_data" | jq -r '.fields.comment.comments[-1].author.displayName // "Unknown"' 2>/dev/null || echo "Unknown")
      latest_comment_body=$(echo "$task_data" | jq -r '.fields.comment.comments[-1].body.content[0].content[0].text // ""' 2>/dev/null || echo "")

      prev_comment_id="${known_comments[$key]:-none}"

      if [[ "$latest_comment_id" != "none" ]] && [[ "$latest_comment_id" != "$prev_comment_id" ]]; then
        # Skip if it's the auto-dev bot's own comment
        if ! echo "$latest_comment_body" | grep -q "Auto-dev"; then
          echo "JIRA_SYNC: New comment on ${key} by ${latest_comment_author}"
          excerpt="${latest_comment_body:0:200}"
          bash "$NOTIFY" jira-update "$key" "New comment by ${latest_comment_author}: ${excerpt}" 2>/dev/null || true
        fi
      fi

      known_comments["$key"]="$latest_comment_id"
    done <<< "$active_sessions"

    # Save updated comment tracking
    : > "$COMMENTS_FILE"
    for k in "${!known_comments[@]}"; do
      echo "${k}=${known_comments[$k]}" >> "$COMMENTS_FILE"
    done
  fi
fi

# --- Save current snapshot ---

echo "$current_raw" > "$KNOWN_FILE"
echo "JIRA_SYNC: Snapshot updated ($(echo "$current_tasks" | grep -c '|' || echo 0) tasks)"
