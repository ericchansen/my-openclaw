# Plans, TODOs, and Task Records

Use three distinct mechanisms. They solve different problems.

## Structured Turn Plan

Use the plan tool for non-trivial work in the current request.

- Write steps as observable outcomes.
- Keep exactly one active step when work is underway.
- Include verification in the plan rather than treating it as an afterthought.
- Update the plan when evidence changes the approach.
- Do not carry a transient plan into durable memory verbatim.

Example:

```text
1. Inspect current schema and preserved channel state
2. Dry-run the minimal configuration patch
3. Apply and validate secrets/channels
4. Verify health and rollback readiness
```

## Durable `TODO.md`

Use the workspace TODO file for commitments that must survive the current session:

```markdown
- [ ] Actionable outcome
  - Owner: parent | user | named system
  - Next action: one concrete step
  - Blocked by: exact dependency, or none
  - Due/review: ISO date if meaningful
  - Source: request or decision date
  - Done when: observable completion test
```

Rules:

- one deliverable per checkbox;
- phrase tasks as actions, not topics;
- record a real next action for every blocker;
- remove or archive completed/stale entries during curation;
- never put credentials, personal transcripts, or speculative promises in TODOs.

## Background Task Ledger

OpenClaw tasks record detached execution; they do not schedule future work. Inspect with:

```bash
openclaw tasks list
openclaw tasks show <task-id>
openclaw tasks audit
openclaw tasks cancel <task-id>
```

Official reference: [Tasks](https://docs.openclaw.ai/tools/tasks).

Use task records for current state and audit evidence. Put durable follow-up in `TODO.md`; use cron for schedules.

## Parent Ownership

Delegated child work remains one parent plan item. Child reports do not close TODOs automatically. The parent calls `sessions_yield`, verifies integrated evidence, then updates the plan/TODO. Only the parent declares completion.

## Triage

At session start:

1. Check relevant durable TODOs.
2. Verify current state before trusting an old blocker.
3. Promote only today's actionable work into the structured plan.
4. Inspect the task ledger only when detached work is actually relevant.

This avoids using one giant list as plan, scheduler, history, and audit log simultaneously.
