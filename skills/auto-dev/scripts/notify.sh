#!/usr/bin/env bash
# notify.sh — Progress notification messages for the auto-dev skill
#
# Since OpenClaw auto-routes responses through the originating messaging channel,
# this script simply formats and outputs progress messages. The OpenClaw agent
# reads the output and sends it to the user's channel.
#
# Commands:
#   starting <KEY> <summary>    Notify that work is starting on a task
#   progress <KEY> <message>    Send a progress update
#   testing <KEY>               Notify that QA testing is starting
#   pr-created <KEY> <url>      Notify that a PR was created
#   error <KEY> <message>       Report an error
#   done                        All tasks complete
set -euo pipefail

cmd_starting() {
  local key="$1"
  shift
  local summary="$*"
  cat <<EOF
🔧 **Starting**: ${key} — ${summary}

I'm picking up this task now. I'll open a Claude Code session, implement the changes, run QA, and create a PR. I'll keep you posted on progress.
EOF
}

cmd_progress() {
  local key="$1"
  shift
  local message="$*"
  echo "⏳ **Progress** [${key}]: ${message}"
}

cmd_testing() {
  local key="$1"
  cat <<EOF
🧪 **QA Testing**: ${key}

Running browser tests to verify the implementation. Will report results shortly.
EOF
}

cmd_pr_created() {
  local key="$1"
  local url="$2"
  cat <<EOF
✅ **PR Ready**: ${key}

Pull request created and ready for review:
${url}

Jira ticket has been moved to "In Review" with the PR link.
EOF
}

cmd_error() {
  local key="$1"
  shift
  local message="$*"
  cat <<EOF
❌ **Error** [${key}]: ${message}

I've added a comment to the Jira ticket with the error details. Moving on to the next task.
EOF
}

cmd_done() {
  cat <<EOF
🏁 **Sprint work complete**

No more tasks in the queue. All assigned tickets have been processed.
EOF
}

cmd_qa_fail() {
  local key="$1"
  shift
  local message="$*"
  cat <<EOF
⚠️ **QA Issue** [${key}]: ${message}

Sending this back to Claude Code for fixing. Will re-test after the fix.
EOF
}

cmd_summary() {
  # Summary of all work done in this session
  local tasks_done="${1:-0}"
  local tasks_failed="${2:-0}"
  local prs_created="${3:-0}"
  cat <<EOF
📊 **Session Summary**

- Tasks completed: ${tasks_done}
- PRs created: ${prs_created}
- Tasks with errors: ${tasks_failed}
EOF
}

# --- Cron daemon notifications ---

cmd_stall() {
  local key="$1"
  shift
  local message="$*"
  echo "⏸️ **Stall Detected** [${key}]: ${message}"
}

cmd_jira_update() {
  local key="$1"
  shift
  local message="$*"
  echo "🔄 **Jira Update** [${key}]: ${message}"
}

cmd_jira_new() {
  local key="$1"
  shift
  local summary="$*"
  cat <<EOF
📋 **New Task Assigned**: ${key} — ${summary}

A new task has been assigned. It will be picked up in the next work cycle.
EOF
}

cmd_heartbeat() {
  shift 2>/dev/null || true
  local message="$*"
  cat <<EOF
💓 **Status Heartbeat**

${message}
EOF
}

cmd_intervention() {
  local key="$1"
  shift
  local message="$*"
  echo "🤖 **Auto-Intervention** [${key}]: ${message}"
}

# --- Router ---

case "${1:-help}" in
  starting)    shift; cmd_starting "$@" ;;
  progress)    shift; cmd_progress "$@" ;;
  testing)     cmd_testing "$2" ;;
  pr-created)  cmd_pr_created "$2" "$3" ;;
  error)       shift; cmd_error "$@" ;;
  done)        cmd_done ;;
  qa-fail)     shift; cmd_qa_fail "$@" ;;
  summary)     cmd_summary "${2:-0}" "${3:-0}" "${4:-0}" ;;
  stall)        shift; cmd_stall "$@" ;;
  jira-update)  shift; cmd_jira_update "$@" ;;
  jira-new)     shift; cmd_jira_new "$@" ;;
  heartbeat)    cmd_heartbeat "$@" ;;
  intervention) shift; cmd_intervention "$@" ;;
  help|*)
    cat <<'USAGE'
Usage: notify.sh <command> [args]

Commands:
  starting <KEY> <summary>        Work starting on a task
  progress <KEY> <message>        Progress update
  testing <KEY>                   QA testing starting
  pr-created <KEY> <url>          PR created and ready for review
  error <KEY> <message>           Error occurred
  done                            All tasks complete
  qa-fail <KEY> <message>         QA found an issue
  summary <done> <failed> <prs>   Session summary
  stall <KEY> <message>           Stall detected by cron monitor
  jira-update <KEY> <message>     Jira change detected by cron sync
  jira-new <KEY> <summary>        New task assigned (from cron sync)
  heartbeat <message>             Periodic status heartbeat
  intervention <KEY> <message>    Auto-intervention taken by cron

Examples:
  notify.sh starting PROJ-123 "Add user authentication"
  notify.sh progress PROJ-123 "Initial implementation complete, running tests"
  notify.sh pr-created PROJ-123 "https://github.com/org/repo/pull/42"
  notify.sh error PROJ-123 "Tests failing after 3 fix attempts"
  notify.sh intervention PROJ-123 "Auto-approved a permission prompt"
USAGE
    ;;
esac
