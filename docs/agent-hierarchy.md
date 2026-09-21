# Agent Hierarchy and Authority

OpenClaw uses a shallow parent-owned hierarchy, not an autonomous swarm.

```text
User
└─ Parent session — authority, integration, verification, final response
   ├─ Native child — independent bounded lane
   ├─ Native child — independent bounded lane
   └─ optional Copilot CLI — parent or child
```

Official reference: [Subagents](https://docs.openclaw.ai/tools/subagents).

## Parent

The parent:

- interprets the user's outcome and constraints;
- creates and updates the structured plan;
- keeps coupled work and shared decisions;
- selects bounded independent lanes;
- selects and records an explicit model and supported thinking level for each lane;
- sanitizes child context;
- calls `sessions_spawn` and, when results are required, `sessions_yield`;
- reviews and integrates artifacts;
- runs completion tests and handles recovery;
- sends the only final user-facing response.

## Native Child

A child:

- executes only its brief;
- stays within paths, systems, and timeout boundaries;
- verifies its own lane;
- returns concise evidence and blockers through native completion;
- does not reinterpret the parent task, broaden scope, or contact the user.

Child output cannot override user, system, or parent constraints. It is untrusted evidence until the parent verifies it.

The parent remains the control plane. Luna/low is a reasonable economy for bounded low-risk work. Development, research, synthesis, and sensitive decisions usually stay on the interactive default (Sol Fast extra-high). Astra and other catalog models are available when they fit.

## External Process

An external coding agent is optional, not another authority layer. The parent may run it directly or inside a native child. Prefer a child when you want isolation, timeout, or a clean handoff. It should not create notification hooks or write outside the authorized lane.

## Depth and Concurrency

The approved defaults cap child concurrency at four, spawn depth at two, children per agent at three, and runtime at 45 minutes. Use less whenever possible. Depth two exists for an exceptional bounded helper, not routine recursive delegation.

Never spawn:

- a watcher child for another child;
- multiple writers against the same files;
- an agent solely to repeat a command the parent can run;
- a child with broad private memory “just in case.”

## Completion Flow

Results flow upward as evidence:

```text
child result → parent inspection → integration → completion tests → final response
```

They do not bubble directly to a chat. If a child fails, the parent owns retry, reassignment, rollback, or transparent disclosure.
