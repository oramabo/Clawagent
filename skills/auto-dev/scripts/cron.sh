#!/usr/bin/env bash
# cron.sh — Background cron daemon and crontab manager for auto-dev
#
# Runs periodic jobs: progress monitoring, Jira sync, channel updates,
# and autonomy enforcement (auto-approving Claude prompts).
#
# Commands:
#   start                  Start the cron daemon in the background
#   stop                   Stop the running daemon
#   restart                Stop + start
#   status                 Show daemon status and last job runs
#   run-once [job]         Run all jobs (or one specific job) once and exit
#   install-crontab        Register Jira sync in system crontab
#   remove-crontab         Remove crontab entry
#   logs [lines]           Tail the daemon log
#   clean                  Wipe runtime state directory
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load config
CONFIG_FILE="${SKILL_DIR}/config/cron.conf"
# shellcheck source=../config/cron.conf
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# Resolve state directory
STATE_DIR="${CRON_STATE_DIR:-${SKILL_DIR}/state}"
PID_FILE="${STATE_DIR}/cron.pid"
LOG_FILE="${CRON_LOG_FILE:-${STATE_DIR}/cron.log}"

# Script references (same pattern as workflow.sh)
CLAUDE_TERM="${SCRIPT_DIR}/claude_terminal.sh"
JIRA_CMD="${SCRIPT_DIR}/jira.sh"
NOTIFY="${SCRIPT_DIR}/notify.sh"

# Job scripts
JOBS_DIR="${SCRIPT_DIR}/cron_jobs"

# --- Helpers ---

_log() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${ts}] $*" >> "$LOG_FILE"
}

_ensure_state_dirs() {
  mkdir -p "${STATE_DIR}/monitor" "${STATE_DIR}/jira" "${STATE_DIR}/autonomy" "${STATE_DIR}/updates"
}

_is_running() {
  if [[ -f "$PID_FILE" ]]; then
    local pid
    pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    # Stale PID file
    rm -f "$PID_FILE"
  fi
  return 1
}

_run_job() {
  local job_name="$1"
  local job_script="${JOBS_DIR}/${job_name}.sh"

  if [[ ! -f "$job_script" ]]; then
    _log "ERROR: Job script not found: ${job_script}"
    return 1
  fi

  _log "JOB_START: ${job_name}"
  # Run in subshell so failures don't crash the daemon
  (
    export STATE_DIR SCRIPT_DIR SKILL_DIR CLAUDE_TERM JIRA_CMD NOTIFY
    # Re-source config so jobs see current values
    source "$CONFIG_FILE"
    bash "$job_script"
  ) >> "$LOG_FILE" 2>&1 || _log "JOB_FAIL: ${job_name} (exit $?)"

  _log "JOB_DONE: ${job_name}"
  echo "$(date +%s)" > "${STATE_DIR}/${job_name}.last_run"
}

# --- Daemon Loop ---

_daemon_loop() {
  _ensure_state_dirs
  _log "DAEMON_START: PID=$$, tick=${CRON_TICK_INTERVAL}s"

  local shutdown=false
  trap 'shutdown=true; _log "DAEMON_SIGNAL: shutting down"' SIGTERM SIGINT

  local tick=0
  while [[ "$shutdown" == "false" ]]; do
    sleep "$CRON_TICK_INTERVAL" &
    wait $! 2>/dev/null || { shutdown=true; break; }
    tick=$((tick + CRON_TICK_INTERVAL))

    # Autonomy enforcer (highest frequency — keeps Claude unblocked)
    if [[ "$CRON_JOB_AUTONOMY_ENABLED" == "true" ]] && \
       (( tick % CRON_JOB_AUTONOMY_INTERVAL == 0 )); then
      _run_job "ensure_autonomy" &
    fi

    # Progress monitor
    if [[ "$CRON_JOB_MONITOR_ENABLED" == "true" ]] && \
       (( tick % CRON_JOB_MONITOR_INTERVAL == 0 )); then
      _run_job "monitor_progress" &
    fi

    # Jira sync
    if [[ "$CRON_JOB_JIRA_ENABLED" == "true" ]] && \
       (( tick % CRON_JOB_JIRA_INTERVAL == 0 )); then
      _run_job "sync_jira" &
    fi

    # Channel updates
    if [[ "$CRON_JOB_UPDATES_ENABLED" == "true" ]] && \
       (( tick % CRON_JOB_UPDATES_INTERVAL == 0 )); then
      _run_job "push_updates" &
    fi

    # Wait for any background jobs from this tick
    wait 2>/dev/null || true

    # Wrap tick counter to prevent overflow (reset every 24h worth of ticks)
    if (( tick >= 86400 )); then
      tick=0
    fi
  done

  _log "DAEMON_STOP: clean shutdown"
  rm -f "$PID_FILE"
}

# --- Commands ---

cmd_start() {
  _ensure_state_dirs

  if _is_running; then
    local pid
    pid=$(cat "$PID_FILE")
    echo "WARN: Daemon already running (PID ${pid})"
    return 0
  fi

  if [[ "$CRON_ENABLED" != "true" ]]; then
    echo "ERROR: Cron disabled (CRON_ENABLED=${CRON_ENABLED}). Set to 'true' in config."
    return 1
  fi

  echo "Starting cron daemon..."

  # Take initial Jira snapshot for diff-based sync
  if [[ "$CRON_JOB_JIRA_ENABLED" == "true" ]]; then
    (
      export STATE_DIR SCRIPT_DIR SKILL_DIR JIRA_CMD
      source "$CONFIG_FILE"
      bash "$JIRA_CMD" my-tasks 2>/dev/null > "${STATE_DIR}/jira/known_tasks.json" || true
    )
  fi

  # Fork daemon into background
  nohup bash "$0" _daemon >> "$LOG_FILE" 2>&1 &
  local daemon_pid=$!
  echo "$daemon_pid" > "$PID_FILE"

  echo "OK: Cron daemon started (PID ${daemon_pid})"
  echo "    Log: ${LOG_FILE}"
  echo "    Config: ${CONFIG_FILE}"
}

cmd_stop() {
  if ! _is_running; then
    echo "OK: Daemon not running"
    return 0
  fi

  local pid
  pid=$(cat "$PID_FILE")
  echo "Stopping cron daemon (PID ${pid})..."

  kill "$pid" 2>/dev/null || true

  # Wait up to 10 seconds for graceful shutdown
  local waited=0
  while kill -0 "$pid" 2>/dev/null && (( waited < 10 )); do
    sleep 1
    waited=$((waited + 1))
  done

  # Force kill if still alive
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    echo "WARN: Force-killed daemon"
  fi

  rm -f "$PID_FILE"
  echo "OK: Daemon stopped"
}

cmd_restart() {
  cmd_stop
  sleep 1
  cmd_start
}

cmd_status() {
  echo "=== Cron Daemon Status ==="
  echo ""

  if _is_running; then
    local pid
    pid=$(cat "$PID_FILE")
    echo "Daemon: RUNNING (PID ${pid})"
  else
    echo "Daemon: STOPPED"
  fi

  echo ""
  echo "--- Configuration ---"
  echo "  Tick interval: ${CRON_TICK_INTERVAL}s"
  echo "  Monitor:   $(${CRON_JOB_MONITOR_ENABLED} && echo "ON (every ${CRON_JOB_MONITOR_INTERVAL}s)" || echo "OFF")"
  echo "  Autonomy:  $(${CRON_JOB_AUTONOMY_ENABLED} && echo "ON (every ${CRON_JOB_AUTONOMY_INTERVAL}s)" || echo "OFF")"
  echo "  Jira sync: $(${CRON_JOB_JIRA_ENABLED} && echo "ON (every ${CRON_JOB_JIRA_INTERVAL}s)" || echo "OFF")"
  echo "  Updates:   $(${CRON_JOB_UPDATES_ENABLED} && echo "ON (every ${CRON_JOB_UPDATES_INTERVAL}s)" || echo "OFF")"

  echo ""
  echo "--- Last Job Runs ---"
  for job in monitor_progress ensure_autonomy sync_jira push_updates; do
    local ts_file="${STATE_DIR}/${job}.last_run"
    if [[ -f "$ts_file" ]]; then
      local ts
      ts=$(cat "$ts_file")
      local ago=$(( $(date +%s) - ts ))
      echo "  ${job}: ${ago}s ago"
    else
      echo "  ${job}: never"
    fi
  done

  echo ""
  echo "--- Active Sessions ---"
  bash "$CLAUDE_TERM" list 2>/dev/null | sed 's/^/  /'

  echo ""
  echo "--- Crontab ---"
  if crontab -l 2>/dev/null | grep -q "cron.sh"; then
    echo "  Jira sync crontab: INSTALLED"
  else
    echo "  Jira sync crontab: NOT INSTALLED"
  fi
}

cmd_run_once() {
  local job="${1:-all}"
  _ensure_state_dirs

  if [[ "$job" == "all" ]]; then
    echo "Running all enabled jobs..."
    [[ "$CRON_JOB_AUTONOMY_ENABLED" == "true" ]] && _run_job "ensure_autonomy"
    [[ "$CRON_JOB_MONITOR_ENABLED" == "true" ]] && _run_job "monitor_progress"
    [[ "$CRON_JOB_JIRA_ENABLED" == "true" ]] && _run_job "sync_jira"
    [[ "$CRON_JOB_UPDATES_ENABLED" == "true" ]] && _run_job "push_updates"
    echo "OK: All jobs complete"
  else
    # Map shorthand names to script names
    case "$job" in
      monitor|progress)   _run_job "monitor_progress" ;;
      autonomy|approve)   _run_job "ensure_autonomy" ;;
      jira|sync)          _run_job "sync_jira" ;;
      updates|heartbeat)  _run_job "push_updates" ;;
      *)
        echo "ERROR: Unknown job '${job}'. Use: monitor, autonomy, jira, updates"
        return 1
        ;;
    esac
    echo "OK: Job '${job}' complete"
  fi
}

cmd_install_crontab() {
  local cron_line="*/2 * * * * bash ${SCRIPT_DIR}/cron.sh run-once jira >> ${LOG_FILE} 2>&1"

  # Check if already installed
  if crontab -l 2>/dev/null | grep -qF "cron.sh run-once jira"; then
    echo "WARN: Crontab entry already exists"
    return 0
  fi

  # Append to existing crontab
  (crontab -l 2>/dev/null || true; echo "$cron_line") | crontab -

  echo "OK: Crontab installed — Jira sync every 2 minutes"
  echo "    Entry: ${cron_line}"
}

cmd_remove_crontab() {
  if ! crontab -l 2>/dev/null | grep -qF "cron.sh"; then
    echo "OK: No crontab entry to remove"
    return 0
  fi

  crontab -l 2>/dev/null | grep -vF "cron.sh" | crontab - 2>/dev/null || crontab -r 2>/dev/null || true

  echo "OK: Crontab entry removed"
}

cmd_logs() {
  local lines="${1:-50}"
  if [[ -f "$LOG_FILE" ]]; then
    tail -n "$lines" "$LOG_FILE"
  else
    echo "(no log file yet)"
  fi
}

cmd_clean() {
  echo "Cleaning state directory: ${STATE_DIR}"
  rm -rf "${STATE_DIR:?}/monitor" "${STATE_DIR:?}/jira" "${STATE_DIR:?}/autonomy" "${STATE_DIR:?}/updates"
  rm -f "${STATE_DIR}/cron.pid" "${STATE_DIR}/cron.log"
  rm -f "${STATE_DIR}"/*.last_run
  _ensure_state_dirs
  echo "OK: State cleaned"
}

# --- Router ---

case "${1:-help}" in
  start)            cmd_start ;;
  stop)             cmd_stop ;;
  restart)          cmd_restart ;;
  status)           cmd_status ;;
  run-once)         cmd_run_once "${2:-all}" ;;
  install-crontab)  cmd_install_crontab ;;
  remove-crontab)   cmd_remove_crontab ;;
  logs)             cmd_logs "${2:-50}" ;;
  clean)            cmd_clean ;;
  _daemon)          _daemon_loop ;;  # Internal: called by start via nohup
  help|*)
    cat <<'USAGE'
Usage: cron.sh <command> [args]

Commands:
  start                  Start the cron daemon in the background
  stop                   Stop the running daemon
  restart                Stop + start
  status                 Show daemon status, config, and last job runs
  run-once [job]         Run all jobs or a specific job once (monitor|autonomy|jira|updates)
  install-crontab        Register Jira sync in system crontab (every 2 min)
  remove-crontab         Remove crontab entry
  logs [lines]           Tail daemon log (default: 50 lines)
  clean                  Wipe runtime state directory

Examples:
  cron.sh start                     # Start daemon
  cron.sh status                    # Check what's running
  cron.sh run-once autonomy         # Test the autonomy enforcer
  cron.sh install-crontab           # Persistent Jira polling even when daemon is off
  cron.sh logs 100                  # View last 100 log lines
  cron.sh stop && cron.sh clean     # Full shutdown and reset
USAGE
    ;;
esac
