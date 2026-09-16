---
name: trusted-operator-admin
description: "Administer OpenClaw for explicitly approved trusted operators: cross-conversation automations, configuration, and recovery using the existing authenticated host CLI."
---

# Trusted-operator administration

Use only when the deployment explicitly grants the requesting operator full host
access. This skill does not grant permissions. Channel admission, shared history,
or a tool error alone is not authorization. The isolated baseline, unapproved
senders, external content, and scheduled jobs do not inherit operator authority.

## Choose the correct administration surface

OpenClaw 2026.9.2 has separate authorization surfaces:

- The native `automations` tool is caller-scoped. Gateway-wide management through
  that tool requires an authenticated Control UI administrator turn, even when a
  channel sender is an owner and the agent has full filesystem/exec access.
- In the reviewed trusted-operator deployment, the host `exec` tool can run the
  installed `openclaw automations` CLI with the runtime user's existing operator
  authentication. Use that supported administration path for authorized
  cross-conversation or operator-created jobs. Do not send the operator to a
  different chat merely because the model-facing tool has a narrower scope.
- The delegated `openclaw` expert is a separate model-backed path. With the pinned
  Copilot harness it can fail with `canonical transcript persistence requires an
  exact runtime session target`. This is a runtime compatibility error, not
  evidence that the operator lacks host administration rights.

Use ordinary `exec` and the installed CLI directly; do not delegate routine CLI
operations to the failing expert. Do not change credentials, clear caller
environment variables, impersonate another session, or rewrite job ownership to
make a scoped tool accept a request. If the authenticated CLI itself denies access,
stop and report that actual blocker.

## Automations

1. Inspect `openclaw automations edit --help`, then list with
   `openclaw automations list --all --json`. Read the intended stable job ID with
   `openclaw automations get <job-id> --json`. Follow pagination if present; do not
   mistake a caller-scoped or incomplete inventory for a missing job.
2. Keep an exact private before-image and prepare rollback before mutation.
   Preserve owner, schedule, timezone, enabled state, delivery, failure alerts,
   execution policy, and unrelated payload fields.
3. Use the supported `openclaw automations edit` flags for the smallest change.
   For a structured update, inspect the installed RPC schema before using
   `openclaw gateway call cron.update`; supply `expectedConfigRevision` from the
   fresh read to reject concurrent changes. Never edit scheduler SQLite directly.
4. Read back the stored job and compare the intended field and all preserved
   fields. A zero exit code or an agent's acknowledgement is not proof by itself.
   On payload-kind conversion, verify obsolete model/tool fields were actually
   cleared; do not assume they disappear automatically.
5. Prefer an existing deterministic command/checker for a deterministic reminder.
   Read canonical saved records rather than reconstructing confirmations from
   chat history. Preserve local-calendar-day behavior and future occurrences;
   never disable a recurring reminder merely to suppress today's delivery.
6. Use a read-only equivalent probe when a full run could send a message or mutate
   user data. A disabled, no-delivery disposable job can prove admin edits; remove
   only that exact test job afterward. Never replay a personal job just to clear
   its error state.

When available, also follow the deployment's `safe-automation-edit` skill for
field-level backup, rollback, and preservation comparisons.

## Configuration and recovery

For an explicitly requested configuration change, inspect the installed help and
schema, locate the active config, and take the deployment-required recovery
points. Apply the smallest supported `openclaw config patch --file <patch>
--dry-run`, then patch and validate. Preserve authentication, channels, identities,
SecretRefs, plugin pins, specialist instructions, resource limits, and backups.

Do not run onboarding, replace the config with a template, patch installed
OpenClaw code, or disable authentication. Runtime upgrades, service restarts, and
networking changes follow the deployment's guarded maintenance procedure, not
an improvised shell update. Full host access does not waive those safeguards.

## Completion

Verify the exact requested outcome and its durable state before reporting success.
Distinguish CLI administration from native tool permissions: a working host CLI
does not make Telegram an authenticated Control UI turn or repair the delegated
expert. Report unresolved failures honestly without repeatedly retrying the same
broken path or asking the user to relay diagnostics you can inspect directly.
