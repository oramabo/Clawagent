# Auto-Dev Workflow Reference

Edge cases and recovery procedures for the auto-dev skill.

## Merge Conflicts

If `git pull` or `git rebase` produces merge conflicts:
1. Send the conflict markers to Claude Code: "We have merge conflicts in these files: <files>. Please resolve them."
2. After resolution, run `git add` on resolved files
3. Continue with `git rebase --continue` or commit the merge
4. Re-run the test suite to verify

## Persistent Test Failures

If tests still fail after 3 fix rounds:
1. Notify the user: "Tests failing after 3 attempts. Needs manual review."
2. Add a Jira comment with the test output
3. Leave the branch as-is (don't delete it)
4. Skip to the next task

## Large Tasks

If the Jira description mentions multiple distinct features:
1. Create subtasks in Jira: `jira.sh create "<subtask summary>" "<desc>" "Sub-task" "<parent-key>"`
2. Work on each subtask individually
3. Each subtask gets its own branch and PR

## No Acceptance Criteria

If the Jira task has no acceptance criteria:
1. Ask Claude Code to infer reasonable criteria from the summary and description
2. Post the inferred criteria as a Jira comment for the user to review
3. Proceed with the inferred criteria

## Browser QA Failures

When the browser skill reports issues:
1. Format the issues clearly (what was expected vs. what happened)
2. Send to Claude Code: "QA found these issues: <issues>. Please fix."
3. After fixes, re-run browser QA
4. Max 3 QA cycles before escalating to user

## Git Conventions

- **Branch naming**: `feat/<JIRA-KEY>` (e.g., `feat/PROJ-123`)
- **Commit format**: `feat(<JIRA-KEY>): <summary>` (e.g., `feat(PROJ-123): Add login form`)
- **PR title**: Same as commit message
- **PR body**: Include Jira link, summary, changes list, and test results

## tmux Session Recovery

If a Claude Code tmux session dies unexpectedly:
1. Check: `claude_terminal.sh status <KEY>`
2. If stopped, start a new session: `claude_terminal.sh start <KEY> <cwd>`
3. Claude Code maintains no state between sessions — re-send context if needed
4. You can use `claude --continue` to resume the last conversation if the session crashed

## Dev Server Management

When starting a dev server for QA:
1. Ask Claude Code to start it in the background
2. Wait a few seconds for it to be ready
3. After QA is done, the dev server will be killed when the tmux session closes
4. If you need to keep it running, start it in a separate tmux window

## Token Budget

Claude Code sessions consume tokens. To stay efficient:
- Keep prompts concise — don't repeat information Claude already has in context
- Use `--max-turns` on follow-ups to prevent runaway sessions
- Close sessions as soon as the task is done
- For very large tasks (10+ files), consider splitting into subtasks
