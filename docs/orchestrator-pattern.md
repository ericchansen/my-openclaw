# Orchestrator Pattern

The orchestrator pattern enables the main agent to delegate complex, long-running tasks to subagents while remaining responsive to user conversations.

## Why Orchestrate?

- **Main session stays free** — Your human can keep chatting while work happens in the background
- **Parallel execution** — Multiple coding tasks can run simultaneously
- **Fault isolation** — If a subagent fails, it doesn't crash the main session
- **Better context** — Each subagent gets focused context for its specific task

## Basic Pattern

```
User: "Fix the auth bug and add tests"
↓
Main Agent: Spawns subagent with specific task
↓
Subagent: Works autonomously (uses Copilot CLI, etc.)
↓
Subagent: Reports completion back
↓
Main Agent: Relays results to user
```

## Spawning Subagents

Use `sessions_spawn` to create focused workers:

```javascript
sessions_spawn({
  label: "auth-fix",
  task: `
    Fix the authentication bug in src/auth.ts.
    
    Setup:
    - Repo: ~/repos/my-app
    - Use Copilot CLI in yolo mode
    
    When done, commit with message "fix: auth validation" and report back.
  `
})
```

### Key Parameters

| Parameter | Purpose |
|-----------|---------|
| `label` | Identifier for the subagent (shows in status) |
| `task` | Detailed instructions — be specific! |
| `model` | Override model (optional) |
| `thinking` | Enable reasoning for complex tasks |

## Best Practices

### 1. Be Explicit in Task Descriptions

Bad:
```
"Fix the bug"
```

Good:
```
"Fix the authentication timeout bug in src/auth/session.ts.
The issue: sessions expire after 1 hour instead of 24 hours.
Look at the SESSION_TTL constant and the refreshToken function.
Commit when fixed."
```

### 2. Include Setup Instructions

```
Setup:
- Socket: /tmp/copilot-agents.sock
- Session: auth-fix
- Repo: ~/repos/my-app

Use Copilot CLI in yolo mode.
```

### 3. Define Completion Criteria

```
When complete:
1. Run tests to verify the fix
2. Commit with conventional commit message
3. Report what changed and test results
```

### 4. Don't Micromanage

The subagent has full context and tools. Let it work. Only intervene if:
- It's been stuck for >10 minutes
- It asks a question you can answer
- It's clearly going down the wrong path

## Monitoring

Check subagent status:
```
subagents({ action: "list" })
```

Steer a running subagent:
```
subagents({
  action: "steer",
  target: "auth-fix",
  message: "Also check the token refresh logic"
})
```

Kill a stuck subagent:
```
subagents({
  action: "kill",
  target: "auth-fix"
})
```

## Push-Based Completion

Subagents automatically announce completion back to their parent. You don't need to poll. Just spawn and wait — results will arrive.

## Multi-Agent Example

Parallel work on multiple tasks:

```javascript
// Spawn three workers simultaneously
sessions_spawn({ label: "api-tests", task: "Add API integration tests..." })
sessions_spawn({ label: "docs-update", task: "Update README with new API..." })
sessions_spawn({ label: "bug-fix", task: "Fix the pagination bug..." })

// Results will arrive as each completes
// Main session stays responsive for conversation
```

## When NOT to Orchestrate

- **Quick questions** — Just answer directly
- **Simple file edits** — Faster to do inline
- **Interactive debugging** — Needs human collaboration
- **Sensitive operations** — Keep in main session for oversight

## Common Patterns

### Code Review

```javascript
sessions_spawn({
  label: "review-pr",
  task: `
    Review PR #42 in ~/repos/my-app.
    Focus on: security, performance, code style.
    Post review comments as a summary.
  `
})
```

### Batch Processing

```javascript
// Process multiple repos
for (const repo of ["app-1", "app-2", "app-3"]) {
  sessions_spawn({
    label: `update-${repo}`,
    task: `Update dependencies in ~/repos/${repo} and run tests.`
  })
}
```

### Research + Implementation

```javascript
// First: research
sessions_spawn({
  label: "research",
  task: "Research OAuth2 PKCE flow best practices. Write findings to /tmp/oauth-research.md"
})

// After research completes, spawn implementation
sessions_spawn({
  label: "implement",
  task: "Implement OAuth2 PKCE based on /tmp/oauth-research.md in ~/repos/my-app"
})
```

## Tips

1. **Label descriptively** — You'll need to identify subagents later
2. **One task per subagent** — Don't bundle unrelated work
3. **Provide context paths** — Absolute paths to repos, files, etc.
4. **Set expectations** — Tell subagent what "done" looks like
5. **Trust the process** — Subagents report back automatically
