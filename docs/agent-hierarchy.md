# Agent Hierarchy

OpenClaw supports a hierarchy of agents with different roles and capabilities.

## Agent Types

### Main Agent

The primary agent that interacts directly with users. It:
- Handles all user conversations
- Has access to full workspace context
- Spawns and manages subagents
- Receives reports from subagents

Configuration:
```json
{
  "agents": {
    "list": [
      {
        "id": "main",
        "default": true,
        "identity": {
          "name": "Agent Name",
          "emoji": "🤖"
        }
      }
    ]
  }
}
```

### Orchestrator Agent

A lightweight coordinator for automated tasks:
- Typically uses a faster, cheaper model
- Good for cron jobs and scheduled work
- Can spawn subagents for complex tasks

```json
{
  "id": "orchestrator",
  "model": "github-copilot/claude-sonnet-4",
  "identity": {
    "name": "Orchestrator",
    "emoji": "🎯"
  }
}
```

### Subagents

Ephemeral workers spawned for specific tasks:
- Created by main agent or orchestrator
- Run in isolation with focused context
- Report completion back to parent
- Terminated after task completion

Subagents are not configured — they're created dynamically:
```javascript
sessions_spawn({
  label: "task-name",
  task: "Description of what to do..."
})
```

## Context Inheritance

Each agent level has different context:

| Agent | Workspace Files | Memory | Session History |
|-------|-----------------|--------|-----------------|
| Main | All | Full MEMORY.md | Full conversation |
| Orchestrator | AGENTS.md, TOOLS.md | Limited | Isolated per task |
| Subagent | Task-specific | None | Fresh each spawn |

## Communication Flow

```
User ←→ Main Agent
              ↓
        Orchestrator (cron tasks)
              ↓
        Subagents (delegated work)
              ↓
        Results bubble up
```

### Main → Subagent

```javascript
sessions_spawn({ label: "fix-bug", task: "..." })
// Subagent works autonomously
// Results announced back when complete
```

### Subagent → Main

Subagents automatically report back via the session system. Their final message becomes a completion notification in the parent session.

### Main → Orchestrator

Orchestrator runs independently on cron schedules. Results are delivered to configured channels:

```json
{
  "cron": {
    "jobs": [
      {
        "id": "daily-check",
        "schedule": "0 9 * * *",
        "agent": "orchestrator",
        "task": "Check inbox and summarize...",
        "deliver": { "channel": "telegram:direct:user" }
      }
    ]
  }
}
```

## Model Selection

Different agents can use different models:

| Use Case | Recommended Model |
|----------|-------------------|
| Main (conversation) | Claude Opus 4.5 (complex reasoning) |
| Orchestrator (automation) | Claude Sonnet 4 (fast, capable) |
| Subagents (coding) | Claude Opus 4.5 or Codex (via Copilot CLI) |

Configure per-agent:
```json
{
  "agents": {
    "defaults": {
      "model": { "primary": "github-copilot/claude-opus-4.5" }
    },
    "list": [
      { "id": "main", "default": true },
      { "id": "orchestrator", "model": "github-copilot/claude-sonnet-4" }
    ]
  }
}
```

## Concurrency Limits

Control how many agents run simultaneously:

```json
{
  "agents": {
    "defaults": {
      "maxConcurrent": 4,
      "subagents": {
        "maxConcurrent": 8
      }
    }
  }
}
```

## Best Practices

1. **Main agent stays responsive** — Delegate long tasks to subagents
2. **Use orchestrator for scheduled work** — Cheaper model, isolated context
3. **Subagents are ephemeral** — Don't expect state persistence
4. **Match model to task** — Complex reasoning needs better models
5. **Trust push-based completion** — Don't poll for subagent status

## Example Setup

A typical configuration with three agent types:

```json
{
  "agents": {
    "defaults": {
      "model": { "primary": "github-copilot/claude-opus-4.5" },
      "workspace": "/home/user/.openclaw/workspace",
      "maxConcurrent": 4,
      "subagents": { "maxConcurrent": 8 }
    },
    "list": [
      {
        "id": "main",
        "default": true,
        "identity": { "name": "Ralph", "emoji": "🦞" }
      },
      {
        "id": "orchestrator",
        "model": "github-copilot/claude-sonnet-4",
        "identity": { "name": "Orchestrator", "emoji": "🎯" }
      }
    ]
  }
}
```

Main handles conversations, orchestrator runs cron jobs, subagents do the heavy lifting.
