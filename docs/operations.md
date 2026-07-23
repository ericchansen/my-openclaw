# Operations and Rollback

## Service Ownership

Systemd owns:

- `openclaw-gateway.service`
- `openclaw-backup.timer` / `openclaw-backup.service`
- `openclaw-health.timer` / `openclaw-health.service`

OpenClaw cron owns precise agent and command jobs. Long-running deterministic watchers should use a supervised service rather than an agent session or polling subagent.

## Health

The local health check emits one bounded redacted JSON record to syslog `local6`. Azure Monitor collects that facility and alerts on:

- VM availability;
- complete schema-v2 health records missing for 50 minutes;
- the same actionable gateway, channel, security, secrets, cron, or task failure present
  in two records separated by at least ten minutes and still present in the latest record;
- stale or failed backups;
- disk use at 75%, 85%, and 92%.

It records counts, booleans, bounded durations, and stable redacted reason categories. It
does not send prompts, responses, channel IDs, credentials, response bodies, or raw audit
findings to Log Analytics. The endpoint probe retries three times before failing. Isolated
endpoint probe failures and generic diagnostic-command failures remain queryable but do
not page by themselves.

Cron scheduler availability is separate from stored job results. Azure considers only
enabled jobs with at least two consecutive execution errors whose last run is within two
hours; an old daily-job failure no longer reports the scheduler unhealthy until the next
day.

The health timer uses a fixed 15-minute calendar schedule with missed-run recovery.
Persistent journald storage is capped at 512 MiB and 30 days so service/timer evidence
survives reboot without unbounded disk growth.

Manual checks:

```bash
curl --fail http://127.0.0.1:18789/health
openclaw status --json
openclaw doctor --lint --json
openclaw channels status --probe --json
openclaw security audit --json
openclaw secrets audit --allow-exec --check --json
openclaw cron status --json
openclaw tasks audit --json
systemctl show openclaw-gateway -p ActiveState -p Result -p NRestarts
```

Use `/health`; do not use a chat-completions route as a monitor because it can create sessions and invoke a model.

## Safe Configuration Change

1. Confirm the active file with `openclaw config file`.
2. Create a verified backup and a succeeded managed-disk snapshot of the current OS disk; record its resource ID.
3. Inspect installed help/schema.
4. Build the smallest JSON5 patch; never replace the live channel configuration with the template.
5. Run `openclaw config patch --file <patch> --dry-run`.
6. Run `openclaw config validate`.
7. Apply one major variable at a time.
8. Restart only after validation.
9. Exercise the affected real channel/tool behavior.
10. Restore the last-known-good file immediately on validation/startup regression.

Invalid config exits with status 78 and the hardened service does not restart-loop it.

## Stable Updates

Weekly:

```bash
openclaw update status --json
openclaw update --dry-run --json
```

Before applying a stable update:

1. create and verify a backup;
2. record Node/OpenClaw/QMD/Copilot versions;
3. check release notes and runtime requirements;
4. update only the intended package/runtime;
5. run config validation and Doctor;
6. cold-restart the gateway;
7. test `/health`, model access, channels, Gmail watch, one deterministic job, one model job, and native child handoff.

Do not automatically install repository `main`, prerelease, or an unbenchmarked model/runtime.
The runtime installer sets `NEEDRESTART_MODE=l`; package maintenance may report pending restarts but must not restart unrelated host services. Restart only the intended service in an operator-controlled window.
On ARM64, Azure Monitor Agent may install its x86 compatibility loader under a physical
`/lib64` directory. Ubuntu 24.04 package upgrades require merged `/usr`; the installer
moves non-conflicting compatibility files to `/usr/lib64` and replaces `/lib64` with the
canonical symlink before invoking apt. A conflicting destination fails closed.

## Incident Sequence

1. Check Azure VM availability and disk pressure.
2. Inspect `systemctl status` and `journalctl -u openclaw-gateway`.
3. Run `/health`, config validation, Doctor, and redacted audit summaries.
4. Check task/cron history rather than starting duplicate work.
5. Preserve logs and diagnostics before cleanup/restart.
6. Use the smallest reversible fix.
7. Verify the originating Telegram/Discord/Gmail behavior, not only HTTP status.

Existing-host infrastructure and runtime scripts require the managed-disk snapshot resource ID and verify that it belongs to the current VM OS disk before mutation.

## Rollback

Configuration/unit rollback:

1. restore the exact pre-change file or unit;
2. restore owner/mode;
3. `systemctl daemon-reload` when units changed;
4. run `openclaw config validate`;
5. restart once;
6. re-probe channels and scheduled work.

Whole-VM rollback:

1. stop mutation and identify the pre-change managed-disk snapshot;
2. preserve the current disk for forensics;
3. follow Azure's supported disk swap/recovery procedure;
4. boot privately;
5. verify SecretRefs, gateway, channels, Gmail, cron, tasks, and backup timers before normal use.

Never rerun onboarding as a rollback mechanism.

## Known Deferred Work

- Public IP and SSH exposure remain unchanged in this pass.
- Storage and Key Vault endpoints remain network-public but require authenticated authorization; private endpoints/firewalls are deferred.
- The VM retains subscription-wide Contributor by explicit owner decision.
- Full OpenClaw archive restore is unavailable in 2026.7.1; use non-destructive verification and the managed-disk recovery point.
