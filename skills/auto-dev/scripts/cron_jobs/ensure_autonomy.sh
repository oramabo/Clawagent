#!/usr/bin/env bash
# ensure_autonomy.sh — Auto-approve prompts, detect crashes, handle fatal errors
#
# For each active autodev session:
#   A) Detects approval/permission prompts and auto-approves (with safety guard)
#   B) Detects Claude crashes (session alive but Claude exited)
#   C) Detects fatal errors (OOM, disk full, etc.)
#
# User choice: auto-approve WITH notification (keeps moving + user stays aware)
#
# Expected env (set by cron.sh):
#   STATE_DIR, SCRIPT_DIR, CLAUDE_TERM, JIRA_CMD, NOTIFY
set -euo pipefail

AUTONOMY_DIR="${STATE_DIR}/autonomy"
mkdir -p "$AUTONOMY_DIR"

# Get active sessions
sessions=$(bash "$CLAUDE_TERM" list 2>/dev/null || true)

if [[ "$sessions" == "(no active sessions)" ]] || [[ -z "$sessions" ]]; then
  exit 0
fi

while IFS= read -r key; do
  [[ -z "$key" ]] && continue

  session_name="autodev-${key}"
  interventions_file="${AUTONOMY_DIR}/${key}.interventions"

  # Load intervention count
  intervention_count=0
  [[ -f "$interventions_file" ]] && intervention_count=$(cat "$interventions_file")

  # Safety: stop auto-approving after max interventions
  if (( intervention_count >= CRON_JOB_AUTONOMY_MAX_INTERVENTIONS )); then
    echo "AUTONOMY [${key}]: Max interventions (${CRON_JOB_AUTONOMY_MAX_INTERVENTIONS}) reached. Skipping."
    continue
  fi

  # Read last 15 lines of terminal
  tail_output=$(bash "$CLAUDE_TERM" read "$key" 15 2>/dev/null || true)
  [[ -z "$tail_output" ]] && continue

  # --- A) Approval Prompt Detection ---

  if echo "$tail_output" | grep -qE "$CRON_JOB_AUTONOMY_APPROVAL_PATTERNS"; then

    # Safety guard: check for destructive operations
    if echo "$tail_output" | grep -qE "$CRON_JOB_AUTONOMY_DESTRUCTIVE_PATTERNS"; then
      echo "AUTONOMY [${key}]: DESTRUCTIVE operation detected — NOT auto-approving"
      bash "$NOTIFY" intervention "$key" \
        "Blocked auto-approval: destructive operation detected. Please review manually." \
        2>/dev/null || true
      continue
    fi

    # Safe to approve
    if [[ "$CRON_JOB_AUTONOMY_AUTO_APPROVE" == "true" ]]; then
      echo "AUTONOMY [${key}]: Auto-approving prompt"

      # Send 'y' + Enter to the tmux session
      tmux send-keys -t "$session_name" "y" Enter 2>/dev/null || true

      # Increment intervention count
      intervention_count=$((intervention_count + 1))
      echo "$intervention_count" > "$interventions_file"

      # Notify user (auto-approve WITH notify)
      bash "$NOTIFY" intervention "$key" \
        "Auto-approved a permission prompt (#${intervention_count}). Claude continues working." \
        2>/dev/null || true
    else
      # Auto-approve disabled — just notify
      bash "$NOTIFY" intervention "$key" \
        "Claude is waiting for approval. Auto-approve is disabled." \
        2>/dev/null || true
    fi

    continue
  fi

  # --- B) Crash Detection ---

  # Check if tmux session exists but shows a shell prompt instead of Claude
  if tmux has-session -t "$session_name" 2>/dev/null; then
    # Look for shell prompt indicators (Claude has exited back to shell)
    if echo "$tail_output" | grep -qE '^\s*(\$|%|#|❯)\s*$'; then
      # Confirm it's not just Claude printing a $ in output
      # Check if the last non-empty line is a bare shell prompt
      last_line=$(echo "$tail_output" | grep -v '^$' | tail -1)
      if echo "$last_line" | grep -qE '^\s*(\$|%|#|❯)\s*$'; then
        echo "AUTONOMY [${key}]: CRASH detected — Claude exited to shell"

        # Get working directory before restart
        cwd=$(tmux display-message -t "$session_name" -p '#{pane_current_path}' 2>/dev/null || echo ".")

        # Restart Claude with --continue to resume context
        tmux send-keys -t "$session_name" "claude --continue" Enter 2>/dev/null || true

        intervention_count=$((intervention_count + 1))
        echo "$intervention_count" > "$interventions_file"

        bash "$NOTIFY" intervention "$key" \
          "Claude crashed and exited to shell. Restarted with --continue to resume." \
          2>/dev/null || true

        continue
      fi
    fi
  fi

  # --- C) Fatal Error Detection ---

  if echo "$tail_output" | grep -qE "$CRON_JOB_AUTONOMY_ERROR_PATTERNS"; then
    echo "AUTONOMY [${key}]: FATAL ERROR detected in terminal output"

    # Extract the error line
    error_line=$(echo "$tail_output" | grep -E "$CRON_JOB_AUTONOMY_ERROR_PATTERNS" | tail -1)

    # Do NOT auto-fix — notify user immediately
    bash "$NOTIFY" intervention "$key" \
      "Fatal error detected: ${error_line}. Manual intervention required." \
      2>/dev/null || true

    # Add Jira comment if jira is available
    bash "$JIRA_CMD" comment "$key" \
      "Auto-dev cron: Fatal error detected in Claude session — ${error_line}" \
      2>/dev/null || true
  fi

done <<< "$sessions"
