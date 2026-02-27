#!/usr/bin/env bash
# claude_terminal.sh — Control Claude Code through a tmux terminal session
#
# This script gives an OpenClaw agent the ability to have a full interactive
# conversation with Claude Code, just like a human developer would.
#
# Commands:
#   start <name> [cwd]         Start a new Claude Code session
#   send <name> <message>      Send a message to the session
#   wait <name> [timeout]      Wait for Claude to finish responding
#   read <name> [lines]        Read recent terminal output
#   status <name>              Check if a session is active
#   stop <name>                Gracefully close the session
#
# No API key needed — uses the logged-in Claude Code subscription.
set -euo pipefail

SESSION_PREFIX="autodev"

# --- Helpers ---

_session_name() {
  echo "${SESSION_PREFIX}-${1}"
}

_require_session() {
  local session="$1"
  if ! tmux has-session -t "$session" 2>/dev/null; then
    echo "ERROR: Session '${session}' does not exist. Run 'start' first."
    return 1
  fi
}

_strip_ansi() {
  # Remove ANSI escape codes (colors, cursor movement, OSC sequences)
  sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' \
    | sed 's/\x1b\][^\x07]*\x07//g' \
    | sed 's/\x1b(B//g' \
    | sed 's/\r//g'
}

# --- Commands ---

cmd_start() {
  local name="$1"
  local cwd="${2:-.}"
  local session
  session=$(_session_name "$name")

  # Don't create duplicate sessions
  if tmux has-session -t "$session" 2>/dev/null; then
    echo "WARN: Session '${session}' already exists. Use 'send' to interact or 'stop' to close it."
    return 0
  fi

  # Resolve working directory to absolute path
  cwd=$(cd "$cwd" && pwd)

  # Create tmux session in detached mode with a large scrollback buffer
  tmux new-session -d -s "$session" -c "$cwd" -x 200 -y 50
  tmux set-option -t "$session" history-limit 10000

  # Launch Claude Code in the session
  tmux send-keys -t "$session" "claude" Enter

  # Wait for Claude Code to initialize
  local elapsed=0
  local max_wait=30
  while [ $elapsed -lt $max_wait ]; do
    sleep 2
    elapsed=$((elapsed + 2))
    local output
    output=$(tmux capture-pane -t "$session" -p 2>/dev/null || true)
    # Check if Claude is ready (look for common prompt indicators)
    if echo "$output" | grep -qiE '(>|claude|ready|help|how can)'; then
      echo "OK: Claude Code session '${session}' started in ${cwd}"
      return 0
    fi
  done

  echo "OK: Claude Code session '${session}' created in ${cwd} (may still be initializing)"
}

cmd_send() {
  local name="$1"
  shift
  local message="$*"
  local session
  session=$(_session_name "$name")
  _require_session "$session"

  # For long messages, write to a temp file and use tmux load-buffer
  # to avoid issues with special characters and length limits
  if [ ${#message} -gt 500 ]; then
    local tmpfile
    tmpfile=$(mktemp /tmp/autodev-msg-XXXXXX)
    echo "$message" > "$tmpfile"

    # Send via tmux buffer to handle long messages properly
    tmux load-buffer -b autodev-buf "$tmpfile"
    tmux paste-buffer -b autodev-buf -t "$session"
    tmux send-keys -t "$session" Enter
    rm -f "$tmpfile"
  else
    # Short messages: send directly with literal flag
    tmux send-keys -t "$session" -l "$message"
    tmux send-keys -t "$session" Enter
  fi

  echo "OK: Message sent to ${session}"
}

cmd_wait() {
  local name="$1"
  local timeout="${2:-300}"
  local session
  session=$(_session_name "$name")
  _require_session "$session"

  local elapsed=0
  local interval=5
  local prev_output=""
  local curr_output=""
  local stable_count=0
  local required_stable=3  # 3 checks * 5s = 15s of stability

  echo "Waiting for Claude to finish (timeout: ${timeout}s)..."

  while [ $elapsed -lt $timeout ]; do
    sleep $interval
    elapsed=$((elapsed + interval))

    # Capture the last few lines of the pane
    curr_output=$(tmux capture-pane -t "$session" -p 2>/dev/null | tail -8 || true)

    if [ "$curr_output" = "$prev_output" ] && [ -n "$curr_output" ]; then
      stable_count=$((stable_count + 1))
      if [ $stable_count -ge $required_stable ]; then
        echo "OK: Claude finished responding (stable for $((interval * stable_count))s)"
        return 0
      fi
    else
      stable_count=0
    fi

    prev_output="$curr_output"
  done

  echo "TIMEOUT: Claude did not finish within ${timeout}s"
  return 1
}

cmd_read() {
  local name="$1"
  local lines="${2:-200}"
  local session
  session=$(_session_name "$name")
  _require_session "$session"

  # Capture scrollback buffer and clean it
  tmux capture-pane -t "$session" -p -S "-${lines}" 2>/dev/null | _strip_ansi
}

cmd_read_last() {
  # Read only the most recent response (after the last user input)
  local name="$1"
  local session
  session=$(_session_name "$name")
  _require_session "$session"

  local full_output
  full_output=$(tmux capture-pane -t "$session" -p -S -500 2>/dev/null | _strip_ansi)

  # Try to extract just the last response by finding the last prompt marker
  # This is heuristic — Claude Code's prompt format may vary
  echo "$full_output" | tac | sed '/^>/q' | tac | tail -n +2
}

cmd_status() {
  local name="$1"
  local session
  session=$(_session_name "$name")

  if tmux has-session -t "$session" 2>/dev/null; then
    local pane_pid
    pane_pid=$(tmux list-panes -t "$session" -F '#{pane_pid}' 2>/dev/null | head -1)
    echo "RUNNING: Session '${session}' is active (pid: ${pane_pid:-unknown})"
    return 0
  else
    echo "STOPPED: Session '${session}' does not exist"
    return 1
  fi
}

cmd_stop() {
  local name="$1"
  local session
  session=$(_session_name "$name")

  if ! tmux has-session -t "$session" 2>/dev/null; then
    echo "OK: Session '${session}' already stopped"
    return 0
  fi

  # Try graceful exit: send /exit to Claude Code
  tmux send-keys -t "$session" "/exit" Enter 2>/dev/null || true
  sleep 3

  # If still alive, send Ctrl-C then exit the shell
  if tmux has-session -t "$session" 2>/dev/null; then
    tmux send-keys -t "$session" C-c 2>/dev/null || true
    sleep 1
    tmux send-keys -t "$session" "exit" Enter 2>/dev/null || true
    sleep 1
  fi

  # Force kill if still alive
  tmux kill-session -t "$session" 2>/dev/null || true
  echo "OK: Session '${session}' stopped"
}

cmd_list() {
  # List all active auto-dev sessions
  tmux list-sessions -F '#{session_name}' 2>/dev/null \
    | grep "^${SESSION_PREFIX}-" \
    | sed "s/^${SESSION_PREFIX}-//" \
    || echo "(no active sessions)"
}

# --- Router ---

case "${1:-help}" in
  start)      cmd_start "$2" "${3:-.}" ;;
  send)       shift; cmd_send "$@" ;;
  wait)       cmd_wait "$2" "${3:-300}" ;;
  read)       cmd_read "$2" "${3:-200}" ;;
  read-last)  cmd_read_last "$2" ;;
  status)     cmd_status "$2" ;;
  stop)       cmd_stop "$2" ;;
  list)       cmd_list ;;
  help|*)
    cat <<'USAGE'
Usage: claude_terminal.sh <command> [args]

Commands:
  start <name> [cwd]        Start Claude Code in a tmux session
  send <name> <message>     Send a message to the session
  wait <name> [timeout_s]   Wait for Claude to finish responding (default: 300s)
  read <name> [lines]       Read terminal output (default: 200 lines)
  read-last <name>          Read only the most recent response
  status <name>             Check if a session exists
  stop <name>               Gracefully close the session
  list                      List all active auto-dev sessions

Examples:
  claude_terminal.sh start PROJ-123 /path/to/repo
  claude_terminal.sh send PROJ-123 "Implement the login feature"
  claude_terminal.sh wait PROJ-123 300
  claude_terminal.sh read PROJ-123
  claude_terminal.sh stop PROJ-123
USAGE
    ;;
esac
