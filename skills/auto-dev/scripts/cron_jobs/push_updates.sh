#!/usr/bin/env bash
# push_updates.sh — Periodic heartbeat updates to communication channels
#
# Sends a combined status summary for all active sessions.
# Deduplicates to avoid spamming identical messages.
#
# Expected env (set by cron.sh):
#   STATE_DIR, SCRIPT_DIR, CLAUDE_TERM, NOTIFY
set -euo pipefail

UPDATES_DIR="${STATE_DIR}/updates"
mkdir -p "$UPDATES_DIR"

LAST_HASH_FILE="${UPDATES_DIR}/last_message_hash"
LAST_TS_FILE="${UPDATES_DIR}/last_update_ts"

# Get active sessions
sessions=$(bash "$CLAUDE_TERM" list 2>/dev/null || true)

if [[ "$sessions" == "(no active sessions)" ]] || [[ -z "$sessions" ]]; then
  if [[ "$CRON_JOB_UPDATES_INCLUDE_IDLE" != "true" ]]; then
    exit 0
  fi
  # Include idle status
  bash "$NOTIFY" heartbeat "No active sessions. Waiting for tasks."
  exit 0
fi

# Build status summary for each session
status_lines=""
while IFS= read -r key; do
  [[ -z "$key" ]] && continue

  # Read phase from monitor state
  phase_file="${STATE_DIR}/monitor/${key}.phase"
  phase="unknown"
  [[ -f "$phase_file" ]] && phase=$(cat "$phase_file")

  # Read last change timestamp from monitor state
  ts_file="${STATE_DIR}/monitor/${key}.last_change_ts"
  ago="?"
  if [[ -f "$ts_file" ]]; then
    last_ts=$(cat "$ts_file")
    now=$(date +%s)
    elapsed=$(( now - last_ts ))
    if (( elapsed < 60 )); then
      ago="${elapsed}s ago"
    elif (( elapsed < 3600 )); then
      ago="$(( elapsed / 60 ))m ago"
    else
      ago="$(( elapsed / 3600 ))h ago"
    fi
  fi

  # Read intervention count
  intervention_file="${STATE_DIR}/autonomy/${key}.interventions"
  interventions=0
  [[ -f "$intervention_file" ]] && interventions=$(cat "$intervention_file")

  line="${key}: ${phase} (last activity ${ago})"
  if (( interventions > 0 )); then
    line="${line}, ${interventions} auto-approvals"
  fi
  status_lines="${status_lines}\n${line}"
done <<< "$sessions"

# Compose the full message
session_count=$(echo "$sessions" | grep -c '.' || echo 0)
message="Active sessions: ${session_count}$(echo -e "$status_lines")"

# Deduplicate: skip if message is identical to last sent
current_hash=$(echo "$message" | md5sum | cut -d' ' -f1)
prev_hash=""
[[ -f "$LAST_HASH_FILE" ]] && prev_hash=$(cat "$LAST_HASH_FILE")

if [[ "$current_hash" == "$prev_hash" ]]; then
  echo "UPDATES: Skipped (identical to last message)"
  exit 0
fi

# Send heartbeat
bash "$NOTIFY" heartbeat "$message"

# Update tracking
echo "$current_hash" > "$LAST_HASH_FILE"
echo "$(date +%s)" > "$LAST_TS_FILE"
echo "UPDATES: Heartbeat sent (${session_count} sessions)"
