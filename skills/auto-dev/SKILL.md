---
name: auto-dev
description: >
  Autonomous developer agent. Picks up Jira tasks, develops solutions through
  full interactive Claude Code terminal sessions (real conversations with
  corrections and follow-ups), QA tests via browser skill, pushes branches,
  creates PRs, updates Jira, and sends progress updates. Use when the user asks
  to work on Jira tickets, develop features, fix bugs, or start sprint work.
  Triggers on: "work on tickets", "develop", "build feature", "fix bug",
  "start sprint", "pick up tasks", "auto dev".
version: 1.0.0
metadata:
  openclaw:
    requires:
      env:
        - JIRA_BASE_URL
        - JIRA_EMAIL
        - JIRA_API_TOKEN
        - JIRA_PROJECT_KEY
      bins:
        - curl
        - jq
        - git
        - gh
        - claude
        - tmux
    primaryEnv: JIRA_API_TOKEN
    emoji: "\U0001F916"
    install: |
      which tmux || echo "Install tmux: apt install tmux / brew install tmux"
      which claude || echo "Install Claude Code: npm install -g @anthropic-ai/claude-code"
      which gh || echo "Install GitHub CLI: https://cli.github.com"
---

# Auto-Dev: Autonomous Developer Agent

You are an autonomous developer. Your job is to pick up Jira tasks, develop
working solutions through real conversations with Claude Code in a terminal,
QA test with the browser skill, push code, and keep the user informed.

**No API key needed** — Claude Code runs with the user's subscription via tmux.

## Preflight

Before starting any work, verify the environment:

```bash
bash {baseDir}/scripts/workflow.sh preflight
```

If any check fails, tell the user what's missing and stop.

---

## Phase 1: Task Discovery

### 1.1 Fetch Assigned Tasks

```bash
bash {baseDir}/scripts/jira.sh my-tasks
```

This returns open tasks assigned to the current user, sorted by priority.

### 1.2 Select a Task

- If `$ARGUMENTS` contains a Jira key (e.g., `PROJ-123`), use that directly
- Otherwise, pick the highest-priority unstarted task from the list
- If no tasks are available, notify the user and stop:
  ```bash
  bash {baseDir}/scripts/notify.sh done
  ```

### 1.3 Fetch Full Details

```bash
bash {baseDir}/scripts/jira.sh get <KEY>
```

Extract: key, summary, description, acceptance criteria, comments, linked issues.

### 1.4 Claim the Task

```bash
bash {baseDir}/scripts/jira.sh transition <KEY> "In Progress"
```

### 1.5 Notify User

```bash
bash {baseDir}/scripts/notify.sh starting <KEY> "<summary>"
```

---

## Phase 2: Development (Interactive Claude Code Session)

This is the core phase. You open a real Claude Code terminal and have a full
conversation — just like a human developer pair-programming with Claude.

### 2.1 Create Working Branch

```bash
git fetch origin main 2>/dev/null || git fetch origin master
git checkout -b feat/<KEY>-<slugified-summary> origin/main 2>/dev/null || \
  git checkout -b feat/<KEY>-<slugified-summary> origin/master
```

Replace spaces/special chars in summary with hyphens, lowercase, max 50 chars.

### 2.2 Start Claude Code Terminal

```bash
bash {baseDir}/scripts/claude_terminal.sh start <KEY> "$(pwd)"
```

This launches Claude Code in a tmux session named `autodev-<KEY>`.

### 2.3 Send the Task

Build the initial prompt using `{baseDir}/assets/prompts/start-task.txt`,
replacing `{TASK_KEY}`, `{TASK_SUMMARY}`, `{TASK_DESCRIPTION}`, and
`{ACCEPTANCE_CRITERIA}` with the Jira data.

```bash
bash {baseDir}/scripts/claude_terminal.sh send <KEY> "<built prompt>"
```

### 2.4 Wait and Review

```bash
bash {baseDir}/scripts/claude_terminal.sh wait <KEY> 300
```

Then read Claude's response:

```bash
bash {baseDir}/scripts/claude_terminal.sh read <KEY>
```

### 2.5 Iterative Conversation (max 10 rounds)

Review Claude's output. For each round:

1. **If tests are failing**: Build a follow-up using `{baseDir}/assets/prompts/fix-tests.txt`
   and send it:
   ```bash
   bash {baseDir}/scripts/claude_terminal.sh send <KEY> "<fix prompt with test output>"
   ```

2. **If code is incomplete**: Send a follow-up describing what's missing:
   ```bash
   bash {baseDir}/scripts/claude_terminal.sh send <KEY> "The <feature> is not yet implemented. Please also add <X>."
   ```

3. **If code looks good and tests pass**: Move to Phase 3.

4. **If max rounds reached without success**: Notify the user:
   ```bash
   bash {baseDir}/scripts/notify.sh error <KEY> "Could not complete after 10 rounds. Manual intervention needed."
   bash {baseDir}/scripts/jira.sh comment <KEY> "Auto-dev: Could not complete implementation after 10 conversation rounds. Needs manual review."
   ```
   Then skip to the next task.

### 2.6 Send Progress Updates

After significant milestones (initial code written, tests fixed, etc.):

```bash
bash {baseDir}/scripts/notify.sh progress <KEY> "<what just happened>"
```

---

## Phase 3: QA (Browser Testing)

After development, test the changes in a real browser using the OpenClaw
browser skill.

### 3.1 Start Dev Server (if applicable)

Ask Claude Code to start the development server:

```bash
bash {baseDir}/scripts/claude_terminal.sh send <KEY> "Start the development server so I can test the changes in a browser. Tell me the URL when it's running."
bash {baseDir}/scripts/claude_terminal.sh wait <KEY> 60
bash {baseDir}/scripts/claude_terminal.sh read <KEY>
```

Extract the local URL from the response (e.g., `http://localhost:3000`).

### 3.2 Notify QA Starting

```bash
bash {baseDir}/scripts/notify.sh testing <KEY>
```

### 3.3 Run Browser Tests

Use the OpenClaw browser skill to:
- Navigate to the local dev server URL
- Test each acceptance criterion from the Jira ticket
- Take screenshots of the results
- Check for visual bugs, broken layouts, console errors

Invoke the browser skill with instructions like:
> Navigate to http://localhost:3000 and test the following:
> 1. <acceptance criterion 1>
> 2. <acceptance criterion 2>
> Report any issues with screenshots.

### 3.4 Handle QA Results

- **QA passes**: Move to Phase 4
- **QA finds issues**: Send them back to Claude Code for fixing:
  ```bash
  bash {baseDir}/scripts/claude_terminal.sh send <KEY> "Browser QA found these issues: <issues>. Please fix them."
  bash {baseDir}/scripts/claude_terminal.sh wait <KEY> 300
  ```
  Then re-run browser QA (max 3 QA cycles).
- **QA fails after 3 cycles**: Notify user and add Jira comment.

---

## Phase 4: Delivery

### 4.1 Self-Review

Send the review prompt to Claude Code:

```bash
bash {baseDir}/scripts/claude_terminal.sh send <KEY> "$(cat {baseDir}/assets/prompts/review-code.txt)"
bash {baseDir}/scripts/claude_terminal.sh wait <KEY> 120
bash {baseDir}/scripts/claude_terminal.sh read <KEY>
```

### 4.2 Commit and Push

```bash
git add -A
git commit -m "feat(<KEY>): <summary>"
git push -u origin feat/<KEY>-<slugified-summary>
```

### 4.3 Create Pull Request

```bash
gh pr create \
  --title "feat(<KEY>): <summary>" \
  --body "## Jira Task
<JIRA_BASE_URL>/browse/<KEY>

## Summary
<summary>

## Changes
<brief description of what was implemented>

## Testing
- Unit tests: passing
- Browser QA: passing"
```

Capture the PR URL from the output.

### 4.4 Update Jira

```bash
bash {baseDir}/scripts/jira.sh transition <KEY> "In Review"
bash {baseDir}/scripts/jira.sh comment <KEY> "Auto-dev completed. PR: <PR_URL>"
```

### 4.5 Notify User

```bash
bash {baseDir}/scripts/notify.sh pr-created <KEY> "<PR_URL>"
```

### 4.6 Clean Up

```bash
bash {baseDir}/scripts/claude_terminal.sh stop <KEY>
```

---

## Phase 5: Loop

Go back to **Phase 1** and pick up the next task.

When there are no more tasks:

```bash
bash {baseDir}/scripts/notify.sh done
```

---

## Error Handling

If any step fails:

1. **Notify the user** with error details:
   ```bash
   bash {baseDir}/scripts/notify.sh error <KEY> "<what failed and why>"
   ```

2. **Add a Jira comment** so the failure is tracked:
   ```bash
   bash {baseDir}/scripts/jira.sh comment <KEY> "Auto-dev error: <details>"
   ```

3. **Clean up** the Claude Code session:
   ```bash
   bash {baseDir}/scripts/claude_terminal.sh stop <KEY> 2>/dev/null || true
   ```

4. **Skip to the next task** — don't block the queue on one failure.

---

## Invocation

- `/auto-dev` — List assigned tasks and start working through them
- `/auto-dev PROJ-123` — Work on a specific ticket
- `/auto-dev --status` — Show active auto-dev sessions
