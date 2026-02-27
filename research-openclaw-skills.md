# Research: OpenClaw Skills Creation

## Context

This document is a comprehensive research summary on OpenClaw and its skill creation system. OpenClaw (formerly Clawdbot/Moltbot) is an open-source, local-first AI agent framework. Skills are the primary extensibility mechanism — modular packages that teach the agent how to perform specific tasks by combining tools.

Both OpenClaw and Claude Code follow the **Agent Skills** open standard (`agentskills.io`), originally created by Anthropic. The SKILL.md format is universal across 26+ platforms including Claude Code, OpenAI Codex, and Cursor.

---

## 1. What is OpenClaw?

- **Created by**: Peter Steinberger, launched late January 2026
- **Stars**: 150k+ GitHub stars (one of the fastest-growing OSS repos ever)
- **Concept**: A persistent, always-on AI assistant you communicate with via messaging platforms (WhatsApp, Telegram, Slack, Discord, Signal, iMessage, etc.)
- **Runs locally**: Laptop, homelab, Raspberry Pi, or VPS — data stays local as Markdown files on disk
- **Model-agnostic**: Works with Claude, GPT, local models on NVIDIA RTX GPUs
- **Architecture**: Hub-and-spoke model with a central Gateway (WebSocket at `ws://127.0.0.1:18789`)
- **Install**: `npm install -g openclaw@latest && openclaw onboard --install-daemon` (requires Node >= 22)

### Key Concepts
- **Tools** = "organs" — determine what OpenClaw *can* do (file system access, shell commands, browser automation)
- **Skills** = "textbooks" — teach OpenClaw *how* to combine tools for specific tasks
- **SOUL.md** = defines agent identity/personality (injected as system prompt on every API call)

---

## 2. Skill Architecture & Structure

### Directory Layout
```
my-skill/
├── SKILL.md           # Required: Main instructions + metadata
├── scripts/           # Optional: Executable code (Python, Shell, JS, etc.)
├── references/        # Optional: Detailed documentation
└── assets/            # Optional: Templates, resources
```

### SKILL.md Format (Two Parts)

**Part 1 — YAML Frontmatter** (between `---` markers): Metadata that tells the agent *when* to use the skill.

**Part 2 — Markdown Body**: Instructions the agent follows *when* the skill is invoked.

### Progressive Disclosure Model (3 Stages)
1. **Discovery**: Only frontmatter (name + description) is read — full content stays on disk
2. **Activation**: When a request matches the description, the full SKILL.md body loads into context (~2,000-5,000 tokens)
3. **Execution**: Agent accesses scripts/assets only when needed during task execution

This allows agents to know about hundreds of skills without overloading the context window.

---

## 3. SKILL.md Frontmatter Reference

### Core Fields (Agent Skills Standard)

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Recommended | Unique skill identifier. Lowercase letters, numbers, hyphens only (max 64 chars). Becomes the `/slash-command`. If omitted, uses directory name. |
| `description` | Recommended | What the skill does and when to use it. Agent uses this to decide when to load it. Critical for discoverability. |
| `argument-hint` | No | Hint shown during autocomplete (e.g., `[issue-number]`, `[filename] [format]`) |
| `disable-model-invocation` | No | `true` = only user can invoke (prevents auto-loading). Default: `false` |
| `user-invocable` | No | `false` = hidden from `/` menu (background knowledge only). Default: `true` |
| `allowed-tools` | No | Tools the agent can use without asking permission when skill is active |
| `model` | No | Model to use when skill is active |
| `context` | No | Set to `fork` to run in a forked subagent context |
| `agent` | No | Which subagent type to use when `context: fork` is set |
| `hooks` | No | Hooks scoped to the skill's lifecycle |

### OpenClaw-Specific Fields (under `metadata.openclaw`)

| Field | Description |
|-------|-------------|
| `metadata.openclaw.requires.env` | Array of required environment variables |
| `metadata.openclaw.requires.bins` | Array of required CLI binaries |
| `metadata.openclaw.requires.config` | Array of required user configuration keys |
| `metadata.openclaw.primaryEnv` | Main credential environment variable |
| `metadata.openclaw.emoji` | Icon displayed when skill activates |
| `metadata.openclaw.install` | Shell commands for first-run initialization |
| `metadata.openclaw.homepage` | URL surfaced as "Website" in the macOS Skills UI |

Aliases: `metadata.clawdbot` and `metadata.clawdis` are also accepted.

### Invocation Control Matrix

| Frontmatter | User Can Invoke | Agent Can Invoke | When Loaded |
|-------------|----------------|-----------------|-------------|
| (default) | Yes | Yes | Description always in context; full skill on invocation |
| `disable-model-invocation: true` | Yes | No | Not in context; loads when user invokes |
| `user-invocable: false` | No | Yes | Description always in context; full skill on invocation |

---

## 4. Complete SKILL.md Examples

### Example 1: Simple Skill (Explain Code)
```yaml
---
name: explain-code
description: Explains code with visual diagrams and analogies. Use when explaining how code works, teaching about a codebase, or when the user asks "how does this work?"
---

When explaining code, always include:

1. **Start with an analogy**: Compare the code to something from everyday life
2. **Draw a diagram**: Use ASCII art to show the flow, structure, or relationships
3. **Walk through the code**: Explain step-by-step what happens
4. **Highlight a gotcha**: What's a common mistake or misconception?

Keep explanations conversational. For complex concepts, use multiple analogies.
```

### Example 2: Task Skill with Arguments
```yaml
---
name: fix-issue
description: Fix a GitHub issue
disable-model-invocation: true
---

Fix GitHub issue $ARGUMENTS following our coding standards.

1. Read the issue description
2. Understand the requirements
3. Implement the fix
4. Write tests
5. Create a commit
```

### Example 3: OpenClaw Skill with Dependencies
```yaml
---
name: todoist-cli
description: Manage Todoist tasks via CLI. Use when user wants to create, list, complete, or organize tasks.
version: 1.2.0
metadata:
  openclaw:
    requires:
      env:
        - TODOIST_API_TOKEN
      bins:
        - curl
        - jq
    primaryEnv: TODOIST_API_TOKEN
    emoji: "✅"
    homepage: https://todoist.com
---

## Managing Tasks

### List tasks
Run: `curl -s -H "Authorization: Bearer $TODOIST_API_TOKEN" https://api.todoist.com/rest/v2/tasks | jq '.[] | {content, due: .due.date}'`

### Create a task
Run: `curl -s -X POST -H "Authorization: Bearer $TODOIST_API_TOKEN" -H "Content-Type: application/json" -d '{"content": "$ARGUMENTS"}' https://api.todoist.com/rest/v2/tasks`
```

### Example 4: Deploy Skill (Manual-Only, Forked Context)
```yaml
---
name: deploy
description: Deploy the application to production
context: fork
disable-model-invocation: true
---

Deploy $ARGUMENTS to production:

1. Run the test suite
2. Build the application
3. Push to the deployment target
4. Verify the deployment succeeded
```

### Example 5: Skill with Dynamic Context Injection
```yaml
---
name: pr-summary
description: Summarize changes in a pull request
context: fork
agent: Explore
allowed-tools: Bash(gh *)
---

## Pull request context
- PR diff: !`gh pr diff`
- PR comments: !`gh pr view --comments`
- Changed files: !`gh pr diff --name-only`

## Your task
Summarize this pull request...
```

The `` !`command` `` syntax runs shell commands *before* the skill content is sent to the agent. Output replaces the placeholder.

---

## 5. String Substitutions

| Variable | Description |
|----------|-------------|
| `$ARGUMENTS` | All arguments passed when invoking the skill |
| `$ARGUMENTS[N]` | Access specific argument by 0-based index |
| `$N` | Shorthand for `$ARGUMENTS[N]` (e.g., `$0`, `$1`) |
| `${CLAUDE_SESSION_ID}` | Current session ID |

---

## 6. Skill Storage Locations

### OpenClaw
| Location | Path | Precedence |
|----------|------|-----------|
| Project/workspace | `<workspace>/skills/` | Highest |
| User | `~/.openclaw/skills/` or `~/.openclaw/workspace/skills/` | Medium |
| Bundled | Built-in skills | Lowest |

### Claude Code
| Location | Path | Applies To |
|----------|------|-----------|
| Enterprise | Managed settings | All org users |
| Personal | `~/.claude/skills/<name>/SKILL.md` | All your projects |
| Project | `.claude/skills/<name>/SKILL.md` | This project only |
| Plugin | `<plugin>/skills/<name>/SKILL.md` | Where plugin is enabled |

Precedence: enterprise > personal > project. Plugin skills are namespaced (`plugin-name:skill-name`).

---

## 7. Publishing to ClawHub

ClawHub (`clawdhub.com`) is the public registry for OpenClaw skills with 5,705+ community skills.

### CLI Commands
- `clawhub login` — Authenticate (GitHub OAuth)
- `clawhub search <query>` — Semantic search via embeddings
- `clawhub install <slug>` — Install a skill locally
- `clawhub publish <path>` — Publish a skill to the registry
- `clawhub sync` — Sync updates

### Install: `npx clawhub@latest install <skill-slug>`

### Publishing Workflow
1. Create your skill directory with SKILL.md
2. Test locally by placing in `~/.openclaw/skills/`
3. Run `clawhub login` to authenticate via GitHub OAuth
4. Run `clawhub publish ./my-skill/` to submit for review
5. ClawHub performs security analysis (frontmatter vs. actual behavior)
6. Once approved, the skill appears in the registry

---

## 8. Best Practices for Skill Creation

1. **Description is critical**: Include all "when to use" keywords in the description — the body only loads after triggering
2. **Keep SKILL.md under 500 lines**: Move detailed reference material to `references/` directory
3. **Write runbooks, not marketing**: The agent needs deterministic steps, stop conditions, and clear output formats
4. **Declare all requirements**: If your code uses an env variable, list it under `requires.env` — metadata mismatches get flagged in review
5. **Include concrete examples**: Agents reproduce patterns more faithfully from concrete examples than abstract instructions
6. **Use `disable-model-invocation: true`** for skills with side effects (deploy, send messages, etc.)
7. **Reference supporting files**: Point to them from SKILL.md so the agent knows what they contain
8. **Name with thematic prefixes**: `review-`, `gen-`, `fix-` for easy autocomplete
9. **Test both invocation paths**: Auto-invocation (matching description) and manual (`/skill-name`)
10. **Version your skills**: Use semantic versioning in the frontmatter for change tracking

---

## 9. Security Considerations

- Treat third-party skills as untrusted code — always review source before enabling
- Skills can contain: prompt injections, tool poisoning, hidden malware payloads, unsafe data handling
- OpenClaw has a VirusTotal partnership for security scanning
- ClawHub performs security analysis on frontmatter vs. actual behavior
- CrowdStrike, 1Password, and Cisco have published guidance on securing OpenClaw deployments
- Consider using ClawSec (https://github.com/prompt-security/clawsec) for drift detection and skill integrity verification

---

## 10. Key Resources & Sources

- [Extend Claude with skills - Claude Code Docs](https://code.claude.com/docs/en/skills)
- [Skills Documentation - OpenClaw](https://docs.openclaw.ai/tools/skills)
- [ClawHub Registry](https://clawdhub.com) / [ClawHub GitHub](https://github.com/openclaw/clawhub)
- [ClawHub Skill Format Spec](https://github.com/openclaw/clawhub/blob/main/docs/skill-format.md)
- [Agent Skills Standard](https://agentskills.io) / [GitHub](https://github.com/agentskills/agentskills)
- [OpenClaw Custom Skill Creation Guide](https://zenvanriel.com/ai-engineer-blog/openclaw-custom-skill-creation-guide/)
- [Build Custom OpenClaw Skills - MarkAICode](https://markaicode.com/build-custom-openclaw-skills/)
- [OpenClaw Skills Guide - LumaDock](https://lumadock.com/tutorials/openclaw-skills-guide)
- [Awesome Claude Code Skills](https://github.com/hesreallyhim/awesome-claude-code)
- [SFEIR Skills Tutorial](https://institute.sfeir.com/en/claude-code/claude-code-custom-commands-and-skills/tutorial/)
- [Claude Code Customization Guide](https://alexop.dev/posts/claude-code-customization-guide-claudemd-skills-subagents/)
- [Awesome OpenClaw Skills](https://github.com/VoltAgent/awesome-openclaw-skills)

---

## Summary

OpenClaw skills follow the **Agent Skills open standard** (SKILL.md format). Creating a skill requires:
1. A directory with a descriptive name
2. A `SKILL.md` file with YAML frontmatter (name, description, requirements) and Markdown instructions
3. Optional scripts, references, and assets
4. Publishing via `clawhub publish` or committing to a project's `skills/` directory

The format is intentionally simple — no SDK, compilation, or runtime needed. Just YAML metadata + Markdown instructions that teach the agent a repeatable way to accomplish a task.
