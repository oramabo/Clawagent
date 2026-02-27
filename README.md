# Clawagent

Autonomous developer agent for [OpenClaw](https://openclaw.ai). Picks up Jira tasks, develops solutions through interactive Claude Code terminal sessions, runs QA in a real browser, pushes branches, creates pull requests, and updates Jira — all without manual intervention.

No API key management needed. Claude Code runs with your existing subscription via tmux.

## How It Works

Clawagent runs a five-phase loop for each Jira task:

1. **Task Discovery** — Fetches your assigned Jira tasks, picks the highest priority one, and claims it.
2. **Interactive Development** — Opens Claude Code in a tmux session and has a real back-and-forth conversation to implement the solution. Iterates up to 10 rounds to fix failing tests.
3. **QA Testing** — Starts a dev server and uses OpenClaw's browser skill to verify each acceptance criterion with real browser testing (up to 3 QA cycles).
4. **Delivery** — Self-reviews code, commits, pushes a feature branch, creates a PR on GitHub, and updates the Jira ticket to "In Review."
5. **Loop** — Picks up the next task. Notifies you when the queue is empty.

## Prerequisites

| Tool | Install |
|------|---------|
| **Claude Code** | `npm install -g @anthropic-ai/claude-code` then `claude login` |
| **tmux** | `apt install tmux` (Linux) or `brew install tmux` (macOS) |
| **GitHub CLI** | [cli.github.com](https://cli.github.com) then `gh auth login` |
| **jq** | `apt install jq` (Linux) or `brew install jq` (macOS) |
| **curl** | Pre-installed on most systems |
| **git** | Pre-installed on most systems |

You also need:

- A **Jira Cloud** account with an API token ([generate one here](https://id.atlassian.com/manage-profile/security/api-tokens))
- A **GitHub** repository with write access

## Installation

### Option 1: Copy into your OpenClaw workspace

```bash
git clone https://github.com/oramabo/Clawagent.git
cp -r Clawagent/skills/auto-dev ~/.openclaw/workspace/skills/
```

### Option 2: Symlink (good for development)

```bash
git clone https://github.com/oramabo/Clawagent.git
ln -s "$(cd Clawagent && pwd)/skills/auto-dev" ~/.openclaw/workspace/skills/auto-dev
```

### Option 3: Paste the repo URL into OpenClaw

Paste `https://github.com/oramabo/Clawagent` into your OpenClaw chat and say "install this skill."

## Configuration

Add your Jira credentials to `~/.openclaw/openclaw.json`:

```json
{
  "skills": {
    "entries": {
      "auto-dev": {
        "enabled": true,
        "env": {
          "JIRA_BASE_URL": "https://yoursite.atlassian.net",
          "JIRA_EMAIL": "you@example.com",
          "JIRA_API_TOKEN": "your-jira-api-token",
          "JIRA_PROJECT_KEY": "PROJ"
        }
      }
    }
  }
}
```

| Variable | Description |
|----------|-------------|
| `JIRA_BASE_URL` | Your Jira Cloud instance URL (e.g. `https://yoursite.atlassian.net`) |
| `JIRA_EMAIL` | Email address associated with your Jira account |
| `JIRA_API_TOKEN` | API token from [Atlassian account settings](https://id.atlassian.com/manage-profile/security/api-tokens) |
| `JIRA_PROJECT_KEY` | Default project key (e.g. `PROJ`) |

## Verify Installation

Run the preflight check to confirm everything is set up correctly:

```bash
bash ~/.openclaw/workspace/skills/auto-dev/scripts/workflow.sh preflight
```

This validates that all required tools are installed, Jira credentials work, you're inside a git repo, and GitHub CLI is authenticated.

## Usage

In your OpenClaw chat:

| Command | What it does |
|---------|-------------|
| `/auto-dev` | List assigned tasks and start working through them |
| `/auto-dev PROJ-123` | Work on a specific Jira ticket |
| `/auto-dev --status` | Show active auto-dev sessions |

You can also trigger it with natural language:

- "Work on my Jira tickets"
- "Build the login feature"
- "Fix bug PROJ-456"
- "Start sprint work"
- "Pick up tasks"

## Project Structure

```
skills/auto-dev/
├── SKILL.md                        # Skill definition and workflow instructions
├── scripts/
│   ├── workflow.sh                 # Orchestration and preflight checks
│   ├── jira.sh                    # Jira Cloud REST API wrapper
│   ├── notify.sh                  # Progress notification formatter
│   └── claude_terminal.sh         # Claude Code tmux session controller
├── assets/prompts/
│   ├── start-task.txt             # Initial task prompt template
│   ├── fix-tests.txt              # Test failure fix prompt template
│   └── review-code.txt            # Self-review prompt template
└── references/
    └── workflow.md                # Edge cases and recovery procedures
```

## Error Handling

Clawagent is designed to keep moving:

- **Failing tests**: Retries up to 10 development rounds with Claude Code
- **QA failures**: Retries up to 3 browser QA cycles
- **Unresolvable issues**: Notifies you, adds a Jira comment with details, and moves to the next task
- **Merge conflicts**: Sends conflicts to Claude Code for resolution
- **Session crashes**: Can recover tmux sessions with `claude --continue`

## License

MIT
