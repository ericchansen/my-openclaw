# Operations and rollback

Use the exact official release and integrity values in
[runtime-versions.json](../config/runtime-versions.json), currently OpenClaw 2026.9.2.
OpenClaw owns heartbeat through its documented defaults; this repository does not
override heartbeat behavior. Systemd does not own heartbeat. Systemd owns the
Gateway, the fifteen-minute runtime health probe, the snapshot timer, and the
deployed OTel collector. Use standard OpenClaw status and Doctor mechanisms for
operator-led diagnostics; do not add a duplicate recurring Doctor schedule.

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
systemctl status openclaw-gateway openclaw-otel-collector \
  openclaw-vm-snapshot.timer openclaw-runtime-health-probe.timer
```

Use `/health`, not a model-backed completion route. A healthy endpoint is not proof
of a working conversation: force the [application canary](availability-recovery.md#application-canary)
and verify the affected real channel/tool. Check VM availability and capacity,
inspect `journalctl -u openclaw-gateway --no-pager`, and preserve private diagnostics
before restart. Inspect task/job history before retrying; never replay personal jobs
merely to clear an alert.

The [runtime health probe](../scripts/openclaw-runtime-health-probe.sh) checks only
the Gateway endpoint/service, memory/load capacity, and root-disk usage. It emits
one `runtime_health_probe` record and exits nonzero when the Gateway or measured
host capacity is unhealthy. It never runs Doctor, task, channel, agent, security,
or other extended diagnostic work.

Diagnostic contacts receive runtime-probe unhealthy/missing, one disk-pressure,
and one capacity-pressure alert. Escalation contacts receive only the sustained
Azure VM-availability outage and its native recovery notification. Budget
recipients remain separate. Contact arrays are declarative parameters, not
discovered from existing groups, and empty arrays explicitly disable that email
route. Both infrastructure modes use the
[shared monitoring module](../infra/monitoring.bicep).

## Safe configuration changes

1. Locate the active file with `openclaw config file`; preserve it and its ownership.
2. Retain the reviewed Git source/IaC commit and create a succeeded current-OS-disk snapshot
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
The interactive default is GPT-5.6 Sol Fast extra-high with Claude Opus 5 extra-high fallback. Astra is available; agents choose. See the [Astra overlay](astra-model.md).

### Trusted operator blocked by a model-facing tool

For `strict inline-eval mode requires reviewer or explicit approval`, inspect
both the global and active agent's `tools.exec.strictInlineEval`. `mode: full`
does not disable that independent gate. The reviewed trusted-operator overlay
sets it to `false` only for `main`, `orchestrator`, and `fitness`; keep the global
and isolated-agent policies intact. Use the installed schema to confirm hot-reload
support, then verify harmless inline interpreter execution through the actual
agent tool rather than direct SSH. Old closed approval requests are not resumed
or approved by changing the policy.

First verify the active agent's full host exec policy and the requesting sender's
reviewed operator grant. In the opt-in production profile, use the existing authenticated host CLI for
cross-conversation jobs. A native
`automations` ownership denial or the Copilot delegated-expert transcript-target
error does not establish that this independent administration path is unavailable.
The [security model](security-model.md#administration-from-trusted-conversations)
documents the distinction and limits.

Preserve the job's stable ID, attribution, timing, destination, and future repeats.
Read back narrow edits; for deterministic checks, prefer canonical saved records
and an existing command checker over a model reading another conversation.
Prove administrative edits with a disposable disabled, no-delivery job rather
than replaying personal reminders. Verify the affected channel session separately;
an operator-injected diagnostic is not proof of real human-message ingress.

### Retiring unused agents

After explicit operator approval, inspect the exact agent's routes, delegation
and credential ownership, automations, active tasks, and workspace/state paths.
No chat bindings does not mean no scheduled work: legacy agents can still have
enabled skill-review jobs and disabled heartbeat jobs. Preserve personal jobs
and active assistants; retire only housekeeping owned by the removed agents.

Follow the pre-change recovery procedure, including a succeeded current-OS-disk
snapshot and the reviewed Git source/IaC commit before removing canonical history.
Inspect the installed `agents delete --help` and use
`openclaw agents delete <reviewed-agent-id> --force --json` against the reachable,
authenticated Gateway. The pinned supported deletion flow removes associated
jobs and prunes owned workspace/state while protecting shared paths and
credential owners. Do not substitute config-only removal or hand-edit SQLite.

Inspect deletion results for failed paths, failed session purges, retained shared
workspaces, or skipped cron cleanup; those are incomplete retirement, not success.
Verify the remaining roster, exact expected job removals, unchanged surviving
jobs/configuration, Gateway health, and active channel routes. Keep recovery
artifacts private and never prune the restricted healthcheck as legacy.

## Stable updates

Existing-host [infrastructure deployment](../deploy.ps1) is snapshot-guarded and
refreshes monitoring only; it does not update OpenClaw or mutate live networking.
Inspect `openclaw update status --json` and `openclaw update --dry-run --json`.
Managed `openclaw update` / `gateway update.run` handoff requires a **user-scope**
systemd unit and is incompatible with this system's
`/etc/systemd/system/openclaw-gateway.service`. Agents on the host must not
refuse authorized updates for that reason, migrate to a user unit, or wait for
a `gateway` tool. Use [apply-runtime.ps1](../scripts/apply-runtime.ps1) for active
custom-systemd hosts; it invokes [openclaw-update](../scripts/openclaw-update.sh)
with recovery evidence. Never substitute a bare global npm update, mutable tag,
or onboarding.
Runtime apply streams the freshness-checked bundle directly to a root process,
verifies its SHA-256, and stages regular files beneath root-owned, non-writable
ancestors. The private staging directory is retained for delayed installer
callbacks and recovery; runtime-user home directories are never execution sources.

The updater checks exact package pins and uses the stable root-owned
`/etc/openclaw/maintenance.lock` for update serialization. Snapshot work uses its
own snapshot lock; the updater pauses the probe and snapshot timers and drains
their services before mutation. Never delete or replace the maintenance-lock
inode or run an update unlocked when it is missing or unsafe.

Only declared OpenClaw timers are paused. Existing snapshot/probe work and visible tasks
drain boundedly; an in-progress snapshot is not killed. Pinned sandbox-image
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
[rollback layers](backup-restore.md#rollback-layers); a downgrade does not undo a
state migration.

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
