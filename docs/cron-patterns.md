# Cron Patterns

OpenClaw supports cron-based scheduling for automated tasks. Use cron for precise timing and isolated execution.

## When to Use Cron vs Heartbeat

| Use Cron | Use Heartbeat |
|----------|---------------|
| Exact timing required | Timing can drift |
| Task needs isolation | Tasks can batch together |
| Different model needed | Same model as main |
| Direct channel delivery | Conversational context needed |
| One-shot reminders | Periodic checks |

## Basic Configuration

```json
{
  "cron": {
    "jobs": [
      {
        "id": "morning-briefing",
        "schedule": "0 9 * * *",
        "agent": "orchestrator",
        "task": "Check calendar, weather, and inbox. Summarize the day ahead.",
        "deliver": {
          "channel": "telegram:direct:user"
        }
      }
    ]
  }
}
```

## Cron Schedule Format

Standard cron syntax: `minute hour day month weekday`

| Field | Values |
|-------|--------|
| Minute | 0-59 |
| Hour | 0-23 |
| Day of Month | 1-31 |
| Month | 1-12 |
| Day of Week | 0-6 (0 = Sunday) |

### Examples

| Schedule | Meaning |
|----------|---------|
| `0 9 * * *` | 9:00 AM daily |
| `0 9 * * 1-5` | 9:00 AM weekdays |
| `*/30 * * * *` | Every 30 minutes |
| `0 */4 * * *` | Every 4 hours |
| `0 9 1 * *` | 9:00 AM on the 1st of each month |
| `0 18 * * 5` | 6:00 PM every Friday |

## Job Configuration

### Required Fields

```json
{
  "id": "unique-job-id",
  "schedule": "0 9 * * *",
  "task": "What the agent should do"
}
```

### Optional Fields

```json
{
  "id": "complex-job",
  "schedule": "0 9 * * 1-5",
  "agent": "orchestrator",
  "model": "github-copilot/claude-sonnet-4",
  "thinking": "low",
  "task": "Analyze weekly metrics and prepare summary",
  "deliver": {
    "channel": "discord:channel:123456789"
  },
  "enabled": true
}
```

| Field | Purpose | Default |
|-------|---------|---------|
| `agent` | Which agent runs the job | `"main"` |
| `model` | Override model for this job | Agent's default |
| `thinking` | Enable reasoning | `"off"` |
| `deliver` | Where to send output | Agent's default channel |
| `enabled` | Toggle job on/off | `true` |

## Delivery Channels

Specify where cron output goes:

```json
"deliver": {
  "channel": "telegram:direct:user"
}
```

Channel formats:
- `telegram:direct:USER_ID`
- `discord:channel:CHANNEL_ID`
- `discord:dm:USER_ID`

## Common Patterns

### Morning Briefing

```json
{
  "id": "morning-briefing",
  "schedule": "0 8 * * 1-5",
  "agent": "orchestrator",
  "task": "Good morning! Check: 1) Today's calendar events, 2) Weather forecast, 3) Unread important emails. Keep it brief.",
  "deliver": { "channel": "telegram:direct:user" }
}
```

### Weekly Review

```json
{
  "id": "weekly-review",
  "schedule": "0 17 * * 5",
  "agent": "orchestrator",
  "thinking": "low",
  "task": "Review this week's memory files. What got done? What's pending? Prepare a brief summary.",
  "deliver": { "channel": "telegram:direct:user" }
}
```

### One-Shot Reminder

Created dynamically via command:
```
/remind in 20 minutes to check the deployment
```

Generates:
```json
{
  "id": "reminder-abc123",
  "schedule": "25 14 18 2 *",
  "task": "Reminder: check the deployment",
  "once": true
}
```

### Repository Monitoring

```json
{
  "id": "repo-check",
  "schedule": "0 */6 * * *",
  "agent": "orchestrator",
  "task": "Check ~/repos/my-app for: 1) Uncommitted changes, 2) Unpushed commits, 3) Failed CI. Report only if issues found.",
  "deliver": { "channel": "discord:channel:123456789" }
}
```

### Backup Reminder

```json
{
  "id": "backup-reminder",
  "schedule": "0 20 * * 0",
  "task": "Weekly backup reminder: Have you backed up your important files this week?",
  "deliver": { "channel": "telegram:direct:user" }
}
```

## Managing Jobs

### List Jobs

```bash
openclaw cron list
```

### Add Job

```bash
openclaw cron add --id daily-check --schedule "0 9 * * *" --task "Check inbox"
```

### Remove Job

```bash
openclaw cron remove daily-check
```

### Disable/Enable

```bash
openclaw cron disable daily-check
openclaw cron enable daily-check
```

## Tips

1. **Use orchestrator for cron** — Cheaper model, isolated context
2. **Be specific in tasks** — Cron jobs don't have conversation history
3. **Set appropriate delivery** — Know where output goes
4. **Test with short intervals** — Debug with `*/5 * * * *` before production
5. **Use `once: true` for reminders** — Auto-cleanup after execution
6. **Batch periodic checks in heartbeat** — Don't create many small cron jobs
7. **Consider timezone** — Server runs in UTC by default

## Debugging

Check cron execution logs:
```bash
journalctl -u openclaw-gateway -f | grep cron
```

Verify job is registered:
```bash
openclaw cron list --verbose
```

Test job manually:
```bash
openclaw cron run daily-check
```
