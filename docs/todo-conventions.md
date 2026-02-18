# TODO Conventions

Guidelines for managing TODO.md and task tracking in your workspace.

## File Location

- **Primary:** `workspace/TODO.md` — Your active task list
- **Archived:** `workspace/memory/` — Move completed items to daily notes

## TODO.md Structure

```markdown
# TODO

## 🔴 Urgent
- [ ] Fix production bug in auth service
- [ ] Respond to client email

## 📋 Active
- [ ] Implement new API endpoint
- [ ] Review PR #42
- [ ] Update documentation

## 📅 Scheduled
- [ ] Monday: Weekly standup prep
- [ ] Friday: Deploy v2.0

## 💡 Ideas / Someday
- [ ] Refactor database layer
- [ ] Explore new caching strategy
- [ ] Write blog post about deployment

## ✅ Recently Completed
- [x] Set up CI/CD pipeline (2024-01-15)
- [x] Fix login redirect bug (2024-01-14)
```

## Priority Levels

| Symbol | Meaning | Action |
|--------|---------|--------|
| 🔴 | Urgent | Do today |
| 📋 | Active | Current sprint/week |
| 📅 | Scheduled | Has a specific date |
| 💡 | Ideas | No timeline, capture for later |
| ✅ | Completed | Move to memory after a few days |

## Task Format

### Basic Task
```markdown
- [ ] Task description
```

### Task with Context
```markdown
- [ ] Task description
  - Context: Why this matters
  - Blocked by: Other task or person
  - Link: https://github.com/issue/123
```

### Task with Date
```markdown
- [ ] Task description (due: 2024-01-20)
- [ ] Another task @2024-01-20
```

## Agent Behavior

### Reading TODO.md

The agent should check TODO.md during:
- Session start (main sessions)
- Heartbeats (if configured)
- When asked about tasks

### Updating TODO.md

When work completes:
```markdown
# Before
- [ ] Fix the auth bug

# After  
- [x] Fix the auth bug (2024-01-15)
```

### Moving Completed Items

Periodically (during heartbeats or cleanup):
1. Move checked items to `memory/YYYY-MM-DD.md`
2. Keep only last 3-5 completed items in TODO.md
3. Archive old items to maintain readability

## Adding Tasks

### Via Conversation

```
User: "Add a task to fix the login page"
Agent: *Updates TODO.md*

Added to TODO.md under 📋 Active:
- [ ] Fix the login page
```

### Via Command

```
/todo add Fix the login page
/todo add urgent Review security audit
/todo list
/todo done "Fix the login page"
```

## Integration with Memory

### Daily Notes

When completing tasks, add context to daily notes:

```markdown
# memory/2024-01-15.md

## Tasks Completed
- Fixed auth bug — was a token expiry issue, added refresh logic
- Reviewed PR #42 — approved with minor suggestions
```

### MEMORY.md

For significant accomplishments, update long-term memory:

```markdown
## Projects

### Auth System Overhaul (Jan 2024)
- Fixed token refresh bug
- Added rate limiting
- Improved error messages
```

## Best Practices

1. **Keep it scannable** — One line per task
2. **Use sections** — Group by priority/category
3. **Add dates** — Know when things were added/completed
4. **Include context** — Future-you will thank you
5. **Regular cleanup** — Archive completed items weekly
6. **Don't over-detail** — This is a list, not documentation

## Example Workflow

### Morning
1. Agent reads TODO.md
2. Mentions urgent items: "You have 2 urgent tasks today"
3. Offers to help with first item

### During Work
1. User completes task
2. Agent marks as done with date
3. Adds brief note to daily memory

### Weekly Review
1. Agent reviews TODO.md during heartbeat
2. Moves old completed items to archive
3. Suggests reprioritizing stale items
4. Updates MEMORY.md with significant completions

## Anti-Patterns

❌ **Don't:**
- Create a new TODO file for each project
- Leave completed items forever
- Add tasks without any priority
- Make tasks too vague ("fix stuff")
- Ignore TODO.md for weeks

✅ **Do:**
- One central TODO.md
- Archive completed items regularly
- Use priority sections
- Be specific ("fix login redirect on mobile Safari")
- Review and update frequently
