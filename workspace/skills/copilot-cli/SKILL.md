---
name: copilot-cli
description: Orchestrate GitHub Copilot CLI sessions via tmux. Use when spawning, steering, or monitoring Copilot CLI coding agents for autonomous coding tasks, multi-repo work, or parallel agent orchestration. Prefer this over Claude Code or Codex.
---

# GitHub Copilot CLI Orchestration

Orchestrate Copilot CLI agents via tmux for autonomous coding tasks.

**Prerequisite:** Read the [tmux skill](/usr/lib/node_modules/openclaw/skills/tmux/SKILL.md) for tmux mechanics (sockets, send-keys, capture-pane). This skill covers Copilot-specific patterns.

## ⚠️ ALWAYS USE SUBAGENTS

**Coding tasks MUST run in a subagent, not the main session.**

The main chat session should stay free for conversation. Spawn a subagent to handle the Copilot CLI work:

```
sessions_spawn(
  label: "coding-task-name",
  task: """
    Launch and steer a Copilot CLI session for [task description].
    
    Setup:
    - Socket: /tmp/copilot-agents.sock
    - Session: [session-name]
    - Repo: [path to repo]
    
    Task: [detailed task description]
    
    When complete, commit the changes and report back.
  """
)
```

The subagent will:
1. Launch Copilot CLI in tmux
2. Send the task and steer the session
3. Handle any questions/prompts
4. Announce completion back to main session

**Never poll Copilot CLI inline in the main session.** This blocks conversation.

## Quick Start

```bash
SOCKET="${TMPDIR:-/tmp}/copilot-agents.sock"
SESSION="copilot-1"

# Create session and launch Copilot CLI in yolo mode
tmux -S "$SOCKET" new-session -d -s "$SESSION" -c ~/repos/my-project
tmux -S "$SOCKET" send-keys -t "$SESSION" "copilot --yolo" Enter

# Wait for startup, then send a task
sleep 3
tmux -S "$SOCKET" send-keys -t "$SESSION" -l -- "Add unit tests for the auth module"
sleep 0.1
tmux -S "$SOCKET" send-keys -t "$SESSION" Enter

# Check output
tmux -S "$SOCKET" capture-pane -p -t "$SESSION" -S -100
```

## Key Flags

| Flag | Purpose |
|------|---------|
| `--yolo` | Auto-approve all tool calls (autonomous mode) |
| `-p "prompt"` | Non-interactive single prompt mode |
| `-s` | Silent mode (output only, no chrome) — combine with `-p` |
| `--allow-tool 'pattern'` | Pre-approve tool patterns (e.g., `'shell(git:*)'`) |
| `--deny-tool 'pattern'` | Block specific tools |

## Prompt Detection

Copilot CLI shows `❯` when ready for input. Check completion:

```bash
if tmux -S "$SOCKET" capture-pane -p -t "$SESSION" -S -5 | grep -q "❯"; then
  echo "Ready for input"
fi
```

For more reliable detection, look for the prompt at end of output:

```bash
tmux -S "$SOCKET" capture-pane -p -t "$SESSION" -S -3 | tail -1 | grep -q "^❯"
```

## Slash Commands

Send these as normal input (with Enter):

| Command | Action |
|---------|--------|
| `/review` | Analyze repo and suggest improvements (great for unfamiliar codebases) |
| `/plan <task>` | Create implementation plan before coding |
| `/model` | Switch models (Opus 4.5, Sonnet 4.5, Codex 5.2) |
| `/delegate <task>` | Offload to cloud coding agent (creates PR) |
| `/clear` or `/new` | Reset context for new task |
| `/session` | View session info and permissions |
| `/context` | Show context window usage |
| `/compact` | Manually trigger context compaction |
| `/help` | Show all commands |

## Sending Commands (Important)

Copilot CLI TUIs can misinterpret fast text+Enter as paste. **Always split text and Enter**:

```bash
tmux -S "$SOCKET" send-keys -t "$SESSION" -l -- "Your prompt here"
sleep 0.1
tmux -S "$SOCKET" send-keys -t "$SESSION" Enter
```

## Control Keys

| Action | Command |
|--------|---------|
| Cancel operation | `tmux -S "$SOCKET" send-keys -t "$SESSION" Escape` |
| Clear/exit | `tmux -S "$SOCKET" send-keys -t "$SESSION" C-c` |
| Clear screen | `tmux -S "$SOCKET" send-keys -t "$SESSION" C-l` |
| Toggle plan mode | `tmux -S "$SOCKET" send-keys -t "$SESSION" S-Tab` |
| View/edit plan | `tmux -S "$SOCKET" send-keys -t "$SESSION" C-y` |

## Multi-Agent Pattern

Spawn multiple agents for parallel work:

```bash
SOCKET="${TMPDIR:-/tmp}/copilot-army.sock"

# Create agents in separate worktrees/repos
for i in 1 2 3; do
  tmux -S "$SOCKET" new-session -d -s "agent-$i" -c ~/repos/project-$i
  tmux -S "$SOCKET" send-keys -t "agent-$i" "copilot --yolo" Enter
done

sleep 3

# Assign tasks
tmux -S "$SOCKET" send-keys -t agent-1 -l -- "Fix the authentication bug"
sleep 0.1 && tmux -S "$SOCKET" send-keys -t agent-1 Enter

tmux -S "$SOCKET" send-keys -t agent-2 -l -- "Add API documentation"
sleep 0.1 && tmux -S "$SOCKET" send-keys -t agent-2 Enter

tmux -S "$SOCKET" send-keys -t agent-3 -l -- "Write integration tests"
sleep 0.1 && tmux -S "$SOCKET" send-keys -t agent-3 Enter
```

## Polling for Completion

```bash
poll_agent() {
  local session="$1"
  local socket="$2"
  local timeout="${3:-300}"
  local interval="${4:-5}"
  local elapsed=0
  
  while [ $elapsed -lt $timeout ]; do
    if tmux -S "$socket" capture-pane -p -t "$session" -S -3 | grep -q "❯"; then
      echo "$session: Complete"
      return 0
    fi
    sleep $interval
    elapsed=$((elapsed + interval))
  done
  echo "$session: Timeout"
  return 1
}

# Usage
poll_agent "agent-1" "$SOCKET" 600
```

## Models

Switch mid-session with `/model`:

| Model | Best For |
|-------|----------|
| Claude Opus 4.6 | Complex architecture, difficult debugging |
| Claude Opus 4.5 | Complex architecture, difficult debugging (default) |
| Claude Sonnet 4.5 | Day-to-day coding, routine tasks (faster, cheaper) |
| GPT-5.2 Codex | Code generation, reviewing other models' output |

## File References

Use `@` to mention files in prompts:

```bash
tmux -S "$SOCKET" send-keys -t "$SESSION" -l -- "Review @src/auth.ts and add error handling"
sleep 0.1 && tmux -S "$SOCKET" send-keys -t "$SESSION" Enter
```

## Plan Mode Workflow

For complex tasks, use plan mode:

```bash
# Enter plan mode
tmux -S "$SOCKET" send-keys -t "$SESSION" -l -- "/plan Add OAuth2 with Google and GitHub"
sleep 0.1 && tmux -S "$SOCKET" send-keys -t "$SESSION" Enter

# Wait for plan generation, then approve
# ... poll for ❯ ...

tmux -S "$SOCKET" send-keys -t "$SESSION" -l -- "Implement this plan"
sleep 0.1 && tmux -S "$SOCKET" send-keys -t "$SESSION" Enter
```

## Cleanup

```bash
# Kill one session
tmux -S "$SOCKET" kill-session -t "$SESSION"

# Kill all sessions on socket
tmux -S "$SOCKET" kill-server
```

## Auto-Notify on Completion

For long-running tasks, tell Copilot to ping OpenClaw when done (instead of waiting for polling):

```bash
tmux -S "$SOCKET" send-keys -t "$SESSION" -l -- "Build the REST API for todos.

When completely finished, run this command to notify me:
openclaw system event --text 'Done: Built todos REST API' --mode now"
sleep 0.1 && tmux -S "$SOCKET" send-keys -t "$SESSION" Enter
```

This triggers an immediate wake event — you get notified in seconds, not minutes.

## Progress Updates (for subagents)

When steering Copilot CLI from a subagent, keep the user informed:

- **Start:** Send 1 short message (what's running + where)
- **Milestones:** Update when something meaningful completes
- **Questions:** Report if Copilot needs input you can't handle
- **Errors:** Report immediately with context
- **Completion:** Summarize what changed + where

Don't spam updates. Don't go silent for 10 minutes either.

## Git Worktrees for Parallel Work

When fixing multiple issues in the same repo, use git worktrees to avoid branch conflicts:

```bash
# Create worktrees for each issue
git worktree add -b fix/issue-78 /tmp/issue-78 main
git worktree add -b fix/issue-99 /tmp/issue-99 main

# Launch Copilot in each
SOCKET="${TMPDIR:-/tmp}/copilot-agents.sock"
tmux -S "$SOCKET" new-session -d -s "issue-78" -c /tmp/issue-78
tmux -S "$SOCKET" send-keys -t "issue-78" "copilot --yolo" Enter

tmux -S "$SOCKET" new-session -d -s "issue-99" -c /tmp/issue-99
tmux -S "$SOCKET" send-keys -t "issue-99" "copilot --yolo" Enter

# After completion, create PRs
cd /tmp/issue-78 && git push -u origin fix/issue-78
gh pr create --title "fix: issue 78" --body "..."

# Cleanup
git worktree remove /tmp/issue-78
git worktree remove /tmp/issue-99
```

## Rules

1. **Be patient** — don't kill sessions because they're "slow". Complex tasks take time.
2. **Respect the working directory** — agent should stay focused on its repo, not wander.
3. **Don't take over** — if Copilot fails/hangs, report back or respawn. Don't silently hand-code the solution yourself.
4. **Monitor with capture-pane** — check progress without interfering.
5. **One task per session** — use `/clear` or `/new` before starting unrelated work.

## Tips

- **Always spawn a subagent** for coding tasks — never block the main session
- Use separate git worktrees for parallel agents (avoids branch conflicts)
- Run `npm install` / dependency setup before launching agent
- Opus 4.5 for complex tasks, Sonnet 4.5 for routine work
- `/delegate` offloads to cloud — good for tangential tasks
- Custom instructions via `AGENTS.md`, `.github/copilot-instructions.md`
- Plan mode requires Shift+Tab to exit before implementation commands work
- Copilot asks clarifying questions via arrow-key menus — subagent can handle these
