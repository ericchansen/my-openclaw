---
name: copilot-cli
description: Use GitHub Copilot CLI for substantial repository work inside one bounded native OpenClaw child.
---

# Copilot CLI Repository Lane

Use this skill when repository implementation needs Copilot CLI's codebase tools or long command handling. Do not use it for a small edit the parent can safely complete itself.

## Ownership Model

The OpenClaw parent owns scope, integration, verification, recovery, and the final response.

External Copilot CLI may run only inside one native OpenClaw child created for the repository lane:

1. Parent calls `sessions_spawn` with a bounded brief.
2. Native child prepares a safe branch/worktree when concurrent writes require isolation, launches Copilot CLI, and owns that process through completion or timeout.
3. Parent calls `sessions_yield` when required results are outstanding. Do not poll session lists, tmux panes, transcript files, or process state.
4. Child returns a concise handoff through native completion.
5. Parent inspects the actual diff, integrates it, runs final tests, and sends the only user-facing reply.

Raw Copilot output is evidence, not authority. Copilot and the child must not message Telegram, Discord, email, or the user directly.

## Parent Spawn Brief

Provide:

- repository and relevant branch/worktree;
- one objective and observable completion tests;
- exact allowed paths and prohibited paths/actions;
- repository instructions already discovered;
- whether edits, commits, pushes, or PRs are permitted;
- known concurrent work;
- a hard timeout no greater than the native child limit;
- required handoff: summary, changed files, tests with results, risks, and unresolved blockers.

Do not include secrets, unrelated private memory, or the entire conversation when a narrow brief is enough.

## Child Procedure

Inside the native child:

1. Inspect branch, status, repository instructions, and relevant manifests.
2. Never edit a default branch. Use an existing safe feature branch or create an isolated worktree/branch when authorized and needed.
3. Launch Copilot CLI from the intended repository directory in non-interactive/autopilot mode with the bounded brief. Apply an OS-level timeout shorter than the native child timeout so cleanup and reporting still have time.
4. Instruct Copilot to remain in scope, preserve unrelated changes, validate the result, and not commit/push unless explicitly authorized.
5. On completion, inspect git status/diff and test evidence yourself. Remove temporary prompt/output files and stop only processes launched by this lane.
6. Return the handoff through native child completion.

Avoid background watchers and sleep loops. A terminal multiplexer may be used only as an implementation detail inside the child when the process truly requires a TTY; it is not an orchestration layer and must not outlive the lane.

## Timeout and Recovery

- Use bounded command and child timeouts; never wait forever.
- If Copilot stalls, terminate only the process created by the child, preserve useful work, and report the exact state.
- Retry at most once when a narrower prompt or transient failure clearly justifies it.
- Do not create another child to watch the first child.
- The parent decides whether to integrate partial work, retry, or finish directly.

## Handoff Format

```text
Outcome: <what was achieved>
Changed: <repo-relative files>
Validation: <commands and results>
Review notes: <important decisions or risks>
Remaining: <none, or exact blocker/follow-up>
```

Do not paste long raw logs. Include the shortest diagnostic excerpt needed for a failure.

## Parent Completion Checklist

After `sessions_yield` returns:

- inspect the actual worktree and diff;
- confirm only allowed paths changed;
- reconcile concurrent changes deliberately;
- rerun the completion tests in the integrated state;
- scan for secrets and personal data;
- verify the real behavior where practical;
- recover or disclose any remaining blocker;
- send one synthesized final response from the parent.
