# Parent-Owned Orchestration

Use OpenClaw's native subagent lifecycle for parallel work. The parent owns the request, integrated state, verification, recovery, and final response.

Official reference: [Subagents](https://docs.openclaw.ai/tools/subagents).

## Lifecycle

1. Define the outcome, constraints, and completion tests.
2. Keep coupled decisions and shared-state edits in the parent.
3. Split only independent, bounded lanes.
4. Spawn each lane with `sessions_spawn`.
5. Continue useful parent work. When required children are outstanding, call `sessions_yield`.
6. Review child reports as evidence.
7. Inspect and integrate actual artifacts, run completion tests, and recover failures.
8. Send one final response from the parent.

`sessions_spawn` is non-blocking. `sessions_yield` is the deliberate handoff point that lets required child completions return natively. Do not replace it with transcript/status polling, shell watchers, sleep loops, or a child that watches another child.

## Good Spawn Brief

Every brief should contain:

- one objective and observable output;
- allowed paths/systems and prohibited actions;
- facts already established;
- required tests and evidence;
- timeout/stopping condition;
- concise return format;
- explicit prohibition on user/channel notification.

Prefer isolated context. Use forked context only when the child needs the current transcript and all inherited material is safe to disclose.

## Bounded Topology

The template uses:

- parent concurrency: 4;
- parent model: GPT-5.6 Sol, high thinking;
- low-risk child default: GPT-5.6 Luna, low thinking;
- delegation mode: prefer;
- child concurrency: 4;
- maximum spawn depth: 2;
- maximum children per agent: 3;
- run timeout: 2,700 seconds.

These are upper bounds, not targets. A single parent often needs zero or one child. Avoid fan-out where the merge cost exceeds the parallel gain.

Sol is the control plane, not merely the most expensive worker. It keeps the user conversation, scope decisions, integration, and final verification. The Luna default is only a safe economy for bounded low-risk work. Every spawn should select its model and thinking level explicitly: use Sol/high for development, multi-source research, ambiguous synthesis, and sensitive decisions. Use Luna/low for mechanical extraction, formatting, or deterministic tool work. Choose Sol when classification is uncertain.

## Repository Lane

For substantial code changes, the parent may create one native child that launches external Copilot CLI. That child owns the external process and reports through native completion. Copilot/tmux is never the top-level orchestration system, never contacts the user, and never decides completion. See `workspace/skills/copilot-cli/SKILL.md`.

## Evidence and Recovery

A child report does not establish that:

- its edits are in the intended worktree;
- concurrent changes were preserved;
- tests cover the requested behavior;
- a successful request represents a working user experience;
- no secret or personal data entered the diff.

The parent checks those conditions. On timeout or failure, preserve useful artifacts, narrow and retry once when justified, or finish in the parent. Report a blocker only after safe recovery paths are exhausted.

## Anti-Patterns

- delegating one coupled change to several writers;
- recursively spawning to “speed up” simple work;
- forwarding raw child output;
- allowing a child to send Telegram/Discord/email;
- polling `sessions_list`, transcripts, tmux panes, or process state;
- marking the plan complete before integrated validation;
- making the child's timeout unbounded.
