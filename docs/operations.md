# Operations and rollback

Use the exact official release and integrity values in
[runtime-versions.json](../config/runtime-versions.json), currently OpenClaw 2026.9.2.
Systemd owns the Gateway, backup/health timers, and deployed OTel collector.
Native OpenClaw automations own scheduled jobs; do not create duplicate schedulers.

## Health and incidents

Run diagnostics as the configured runtime user; keep raw output private:

```bash
curl --fail http://127.0.0.1:18789/health
openclaw config validate
openclaw doctor --lint --json
openclaw channels status --probe --json
openclaw security audit --json
openclaw secrets audit --allow-exec --check --json
openclaw automations status --json
openclaw automations list --all --json
openclaw tasks audit --json
openclaw tasks list --runtime subagent --json
systemctl status openclaw-gateway openclaw-otel-collector openclaw-backup.timer openclaw-health.timer
```

Use `/health`, not a model-backed completion route. A healthy endpoint is not proof
of a working conversation: force the [application canary](availability-recovery.md#application-canary)
and verify the affected real channel/tool. Check VM availability and capacity,
inspect `journalctl -u openclaw-gateway --no-pager`, and preserve private diagnostics
before restart. Inspect task/job history before retrying; never replay personal jobs
merely to clear an alert.

The [health helper](../scripts/openclaw-health-check.sh) emits bounded redacted
records, including early capacity samples. Unknown diagnostics remain unknown.
Capacity alerts do not authorize disabling features or changing service budgets:
capture process/cgroup attribution first. Health scheduling lives in [config](../config/);
both infrastructure modes use the [shared monitoring module](../infra/monitoring.bicep).

Task settlement checks cover visible terminal subagent tasks with unfinished
notification delivery, not hidden queue corruption. The helper's
`OPENCLAW_TASK_SETTLEMENT_MAX_AGE_SECONDS` defaults to 2400 (allowed 60–3600).
Preserve the margin over the upstream
[30-minute required-delivery window](https://github.com/openclaw/openclaw/blob/v2026.9.2/src/agents/subagents/registry/subagent-registry-helpers.ts).
An empty task inventory or passing canary cannot establish that old task delivery
is repaired; malformed/incomplete inventories fail closed.

## Safe configuration changes

1. Locate the active file with `openclaw config file`; preserve it and its ownership.
2. Create a verified backup and succeeded current-OS-disk snapshot
   using [the recovery procedure](backup-restore.md#pre-change-recovery-point).
3. Inspect installed help/schema and prepare the smallest reviewed patch.
4. Dry-run with `openclaw config patch --file <patch> --dry-run`, then apply through
   the supported CLI and run `openclaw config validate` before restart.
5. Change one major variable at a time; compare native automation status/list
   before and after, then verify the originating conversation, affected tools,
   scheduled execution, and forced canary after activation.

Do not replace live channels with a template. Review identities, owner command
grants, agent routing, plugin allowlist additions, and model overrides separately.
Preserve existing approved family configuration; future identity/sharing changes
need explicit review, not an implicit grant from this upgrade.
For the current production model use the prerequisite-gated [Astra overlay](astra-model.md).

## Stable updates

Existing-host [infrastructure deployment](../deploy.ps1) is snapshot-guarded and
refreshes monitoring only; it does not update OpenClaw or mutate live networking.
Inspect `openclaw update status --json` and `openclaw update --dry-run --json`.
Use [apply-runtime.ps1](../scripts/apply-runtime.ps1) for active custom-systemd
hosts; it invokes [openclaw-update](../scripts/openclaw-update.sh) with recovery
evidence. Never substitute a bare global npm update, mutable tag, or onboarding.
Runtime apply streams the freshness-checked bundle directly to a root process,
verifies its SHA-256, and stages regular files beneath root-owned, non-writable
ancestors. The private staging directory is retained for delayed installer
callbacks and recovery; runtime-user home directories are never execution sources.

The updater re-verifies the native archive, checks exact package pins, and shares
the stable root-owned `/etc/openclaw/maintenance.lock` with backup/health readers.
Maintenance takes an exclusive lock; contention exits before mutation.
Never delete/replace that inode or run unlocked when it is missing or unsafe.

Only OpenClaw timers are paused. Existing backup/health work and visible tasks
drain boundedly; an in-progress backup is not killed. Pinned sandbox-image
provisioning runs before Gateway shutdown. A pre-shutdown failure leaves the
working Gateway unchanged and restores previously active timers.

Package mutation, update repair, config validation, and Doctor run while stopped.
The stopped-runtime installer applies assets under the same lock. Start once,
prove readiness and the exact running version, then resume timers after lock
release. Failure after mutation deliberately leaves Gateway and timers stopped
for operator recovery: **there is no automatic package/state rollback**.
Do not restart Docker or unrelated host services; recreate only OpenClaw-owned
containers in an approved window.

## Rollback and service failures

For config/unit rollback, restore the exact pre-change files and ownership,
reload systemd if units changed, validate, and start once. Recheck real channels,
tools, jobs, and timers. Package, state, and disk recovery are separate
[rollback layers](backup-restore.md#rollback-layers); a downgrade does not undo SQLite migration.

The [Gateway unit](../config/openclaw-gateway.service) uses `Restart=always` because
a config reload can exit successfully. Exit 78 blocks invalid-config restart loops;
an explicit operator stop stays stopped. Do not replace this with `on-failure`.
Keep the deployed metadata collector and [launcher](../scripts/openclaw-gateway-launch.py)
guards intact; inspect collector readiness rather than removing telemetry to start.
Future private-network/NAT cutover is deferred, not an incident-recovery prerequisite.

## Validation

Run `pwsh scripts/test-repository.ps1` from the repository. Exact-runtime checks use
isolated state, not production. Windows unit verification uses WSL and
`systemd-analyze`; `-SkipSystemdValidation` is an explicit test-only skip, not a pass.
Regenerate changed bootstrap assets with
[sync-cloud-init-assets.ps1](../scripts/sync-cloud-init-assets.ps1).
Repository checks are not live acceptance; follow [availability acceptance](availability-recovery.md#acceptance-and-remaining-boundaries).
