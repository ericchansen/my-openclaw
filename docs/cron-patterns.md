# Cron and Scheduled Work

Manage schedules with the OpenClaw cron CLI, not an `openclaw.json` jobs array. Tasks are execution records, not a scheduler.

Official references: [Cron jobs](https://docs.openclaw.ai/automation/cron-jobs) and [CLI cron](https://docs.openclaw.ai/cli/cron).

## Inspect Before Changing

```bash
openclaw cron list
openclaw cron show <job-id>
openclaw cron runs --id <job-id>
```

Use `openclaw cron create --help` and `openclaw cron edit --help` from the installed version before composing a production command. Do not recreate existing Telegram, Discord, Gmail, or operational jobs during a config migration.

## Choose the Smallest Job Type

### Deterministic command

Prefer command jobs for scripts or CLIs with fixed inputs and outputs:

- exact executable and argv; no shell interpolation when avoidable;
- dedicated service identity and least privilege;
- bounded runtime and output;
- idempotency or a run key;
- explicit success criterion;
- failure alert and tested destination.

Never place secret values in command arguments, job names, prompts, or delivery text. Resolve them at execution through the approved SecretRef/managed-identity path.

### Isolated agent

Use an isolated agent only when interpretation or synthesis is necessary:

- use `--light-context`;
- set model, fallback sequence, and thinking explicitly;
- provide one bounded prompt and completion criterion;
- set a timeout below the scheduler's maximum;
- deliver only the synthesized result;
- configure failure alerts.

Do not use cron to create an unbounded orchestration session. The scheduled parent still owns any native children and must use `sessions_yield`, verify their evidence, and synthesize the delivery.

### Model policy

The interactive parent uses GPT-5.6 Sol as the control plane. Persist each automation's execution policy instead of inheriting whichever interactive model happens to be current:

- no model for deterministic scripts, probes, backups, renewals, and exact transformations;
- `github-copilot/gpt-5.6-luna` with low thinking for bounded, low-risk extraction, formatting, or triage;
- `github-copilot/gpt-5.6-sol` with high thinking for development, multi-source research, ambiguous synthesis, or sensitive outcomes;
- choose Sol when classification is uncertain.

Sol may select this policy when it creates or edits a job, but the stored job remains explicit and auditable. Do not let a heartbeat silently rewrite existing job policy.

## Example Creation Workflow

Flags can evolve; confirm them against installed `2026.7.1` help:

```bash
openclaw cron create --help
openclaw cron create \
  --name "weekly-quality-report" \
  --cron "0 9 * * 1" \
  --tz "UTC" \
  --session isolated \
  --light-context \
  --model "github-copilot/gpt-5.6-sol" \
  --fallbacks "github-copilot/claude-sonnet-5" \
  --thinking "high" \
  --timeout-seconds 900 \
  --announce \
  --channel telegram \
  --to "<approved-destination>" \
  --message "<bounded report prompt>"

openclaw cron edit <job-id> \
  --failure-alert \
  --failure-alert-after 1 \
  --failure-alert-cooldown "6h" \
  --failure-alert-channel telegram \
  --failure-alert-to "<approved-destination>"
```

`cron create` does not accept failure-alert flags in 2026.7.1, so configure them with `cron edit` after capturing the new job ID. Use `openclaw cron run <job-id>` for a controlled test, then inspect `openclaw cron runs --id <job-id>`. Prefer editing an existing job to delete/recreate so run history and identity remain clear.

For daily user-facing synthesis jobs, start with two consecutive execution errors,
exclude scheduler skips, and use the existing delivery route unless a separate operational
destination is required. This reports a real retry sequence without turning a retained
daily-job error into a day-long platform outage. Keep Azure scheduler health separate from
the job's built-in failure delivery.

## Reliability Checklist

- timezone and daylight-saving behavior are explicit;
- overlapping runs are prevented or safe;
- timeout leaves time for cleanup and alerting;
- model fallback is observable in the result/log;
- delivery failure is distinct from work failure;
- skipped-run and repeated-failure behavior is configured;
- alert destination was tested without sensitive content;
- job can be retried safely;
- ownership and rollback are documented.

Use a heartbeat only for a few batched, context-aware checks that tolerate drift. The template runs a lightweight isolated Sol heartbeat every two hours; it should classify and delegate bounded work rather than execute a long workflow inline. Use cron for exact timing and isolated execution.
