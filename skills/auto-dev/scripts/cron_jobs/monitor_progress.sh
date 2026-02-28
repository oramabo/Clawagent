#!/usr/bin/env bash
# monitor_progress.sh — Periodic progress monitor for active Claude sessions
#
# For each active autodev session:
#   - Captures terminal output and hashes it
#   - Detects stalls (no output change beyond threshold)
#   - Detects phase (working, testing, error, idle, complete)
#   - Takes configured action on stall (nudge, notify, restart)
#
# Expected env (set by cron.sh):
#   STATE_DIR, SCRIPT_DIR, CLAUDE_TERM, NOTIFY
set -euo pipefail

MONITOR_DIR="${STATE_DIR}/monitor"
mkdir -p "$MONITOR_DIR"

# Get list of active sessions
sessions=$(bash "$CLAUDE_TERM" list 2>/dev/null || true)

if [[ "$sessions" == "(no active sessions)" ]] || [[ -z "$sessions" ]]; then
  exit 0
fi

_detect_phase() {
  local output="$1"

  if echo "$output" | grep -qiE '(All.*tests? passed|Build successful|✓.*pass|0 failing)'; then
    echo "complete"
  elif echo "$output" | grep -qiE '(FAIL|ERROR|Traceback|SyntaxError|TypeError|ReferenceError|panic:)'; then
    echo "error"
  elif echo "$output" | grep -qiE '(Creating|Modifying|Reading|Writing|Running|Editing|Installing)'; then
    echo "working"
  elif echo "$output" | grep -qiE '(^>$|How can I help|What would you like)'; then
    echo "idle"
  else
    echo "active"
  fi
}

while IFS= read -r key; do
  [[ -z "$key" ]] && continue

  # Capture terminal output
  output=$(bash "$CLAUDE_TERM" read "$key" 50 2>/dev/null || true)
  [[ -z "$output" ]] && continue

  # Hash current output
  current_hash=$(echo "$output" | md5sum | cut -d' ' -f1)
  hash_file="${MONITOR_DIR}/${key}.last_hash"
  ts_file="${MONITOR_DIR}/${key}.last_change_ts"
  stall_file="${MONITOR_DIR}/${key}.stall_count"
  phase_file="${MONITOR_DIR}/${key}.phase"

  # Detect phase and persist
  phase=$(_detect_phase "$output")
  echo "$phase" > "$phase_file"

  # Load previous hash
  prev_hash=""
  [[ -f "$hash_file" ]] && prev_hash=$(cat "$hash_file")

  if [[ "$current_hash" != "$prev_hash" ]]; then
    # Output changed — reset stall tracking
    echo "$current_hash" > "$hash_file"
    echo "$(date +%s)" > "$ts_file"
    echo "0" > "$stall_file"

    # Log phase transition
    echo "MONITOR [${key}]: phase=${phase}, output changed"
  else
    # Output unchanged — track stall duration
    last_change=0
    [[ -f "$ts_file" ]] && last_change=$(cat "$ts_file")
    now=$(date +%s)
    unchanged_for=$(( now - last_change ))

    stall_count=0
    [[ -f "$stall_file" ]] && stall_count=$(cat "$stall_file")

    if (( unchanged_for >= CRON_JOB_MONITOR_STALL_THRESHOLD )); then
      stall_count=$((stall_count + 1))
      echo "$stall_count" > "$stall_file"

      echo "MONITOR [${key}]: STALL detected (${unchanged_for}s unchanged, count=${stall_count})"

      case "${CRON_JOB_MONITOR_STALL_ACTION}" in
        nudge)
          # Send a nudge to Claude and notify user
          bash "$CLAUDE_TERM" send "$key" \
            "It seems like you may be stuck. Please continue working on the task. If you need clarification, describe what's blocking you." \
            2>/dev/null || true
          bash "$NOTIFY" stall "$key" "No output change for ${unchanged_for}s. Sent nudge to Claude."
          # Reset the timestamp so we don't spam nudges every tick
          echo "$(date +%s)" > "$ts_file"
          ;;
        notify)
          # Only notify user, don't nudge Claude
          bash "$NOTIFY" stall "$key" "No output change for ${unchanged_for}s. Claude may be stalled."
          echo "$(date +%s)" > "$ts_file"
          ;;
        restart)
          # Restart Claude session with --continue
          bash "$NOTIFY" stall "$key" "No output change for ${unchanged_for}s. Restarting Claude session."
          cwd=$(tmux display-message -t "autodev-${key}" -p '#{pane_current_path}' 2>/dev/null || echo ".")
          bash "$CLAUDE_TERM" stop "$key" 2>/dev/null || true
          sleep 2
          bash "$CLAUDE_TERM" start "$key" "$cwd" 2>/dev/null || true
          sleep 3
          bash "$CLAUDE_TERM" send "$key" "/resume" 2>/dev/null || true
          echo "0" > "$stall_file"
          echo "$(date +%s)" > "$ts_file"
          ;;
      esac
    fi
  fi
done <<< "$sessions"
