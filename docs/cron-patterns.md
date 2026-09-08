# Automations and Scheduled Work

Manage schedules with `openclaw automations`, the primary `2026.9.1` CLI name.
`openclaw cron` remains an alias and `cron.*` remains the persisted
configuration/runtime JSON namespace. Tasks are execution records, not a
scheduler.

Official references:
[automations](https://github.com/openclaw/openclaw/blob/v2026.9.1/docs/automation/cron-jobs.md)
and [CLI](https://github.com/openclaw/openclaw/blob/v2026.9.1/docs/cli/cron.md).

## Inventory before mutation

```bash
openclaw automations status --json
openclaw automations list --all --json
openclaw automations show <job-id>
openclaw automations runs --id <job-id>
```

Compare the native inventory before and after reviewed in-place edits; do not
recreate jobs during migration. Inventory output can contain private prompts,
commands and recipients: keep any saved copy private and do not commit it.

## Runtime policy

`cron.skipMissedJobs: true` is the chosen policy: recurring slots missed while
the Gateway was offline advance to the next future occurrence. One-shot jobs
retain upstream catch-up semantics. This avoids stale side effects; it may drop
offline recurring work.

Existing jobs are preserved. Review any job whose `sessionTarget` is not
`isolated`; change it in place only after checking its intended context and
delivery. New model-backed jobs should use isolated sessions, explicit
model/fallback/thinking, a bounded timeout, and failure alerts.

Use deterministic command jobs for fixed scripts and isolated agent jobs only
for interpretation or synthesis. Never put secret values in arguments, names,
prompts, or delivery text. Resolve them through approved SecretRefs.

## Creation example

Confirm exact flags first:

```bash
openclaw automations add --help
openclaw automations add "0 9 * * 1" \
  "<bounded report prompt>" \
  --name "weekly-quality-report" \
  --tz "UTC" \
  --session isolated \
  --light-context \
  --model "github-copilot/gpt-5.6-sol" \
  --fallbacks "github-copilot/claude-sonnet-5" \
  --thinking "high" \
  --timeout-seconds 900 \
  --announce \
  --channel telegram \
  --to "<approved-destination>"

openclaw automations edit <job-id> \
  --failure-alert \
  --failure-alert-after 1 \
  --failure-alert-cooldown "6h" \
  --failure-alert-exclude-skipped \
  --failure-alert-channel telegram \
  --failure-alert-to "<approved-destination>"
```

Creation does not accept failure-alert flags in `2026.9.1`; apply them with an
in-place edit. Test with `openclaw automations run <job-id> --wait`, then inspect
the exact run. Execution `status` and whole-run `completionStatus` are distinct;
delivery status is separate again. A successful execution with failed required
delivery is not a successful completed automation.

## Reliability checklist

- timezone and daylight-saving behavior are explicit;
- overlap and retries are safe;
- timeout leaves cleanup/alert time;
- failure alerts distinguish execution errors from delivery failures;
- skipped runs do not count as execution errors unless explicitly selected;
- destination tests contain no sensitive content;
- run history and job identity survive edits;
- owner and rollback are documented.

Heartbeats are for a few context-aware checks that tolerate drift.
Automations own exact timing and isolated execution.
