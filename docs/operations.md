# Operate this installation

The Gateway runs as `/etc/systemd/system/openclaw-gateway.service`, under
`azureuser`, rather than an OpenClaw-managed user service. The repository also
installs a fifteen-minute runtime health probe, daily snapshot timer, and local
OpenTelemetry collector. Software pins are in
[runtime-versions.json](../config/runtime-versions.json).

## Diagnostics

On the VM:

```bash
curl --fail http://127.0.0.1:18789/health
systemctl status openclaw-gateway openclaw-otel-collector \
  openclaw-runtime-health-probe.timer openclaw-vm-snapshot.timer
sudo journalctl -u openclaw-gateway --since "30 minutes ago" --no-pager
```

The runtime probe measures Gateway service/HTTP health, host capacity, and disk
usage. It does not run a model or test channel delivery.

For an operator-led model/tool check, the installed internal healthcheck uses
an isolated workspace and sandboxed exec, with no browser, private memory, or
message delivery:

```bash
python3 /usr/local/libexec/openclaw-availability-check \
  --status-file /var/lib/openclaw-runtime/availability.json --force
```

For channel, browser, automation, and model diagnostics use the
[OpenClaw troubleshooting reference](https://docs.openclaw.ai/gateway/troubleshooting).
Verify the affected operation in its real conversation; the internal check
does not exercise personal workflows. Diagnostic output can contain private data.

Diagnostic notification recipients get probe, disk, and capacity alerts.
Escalation recipients get sustained VM-availability outage/recovery notifications.
The subscription budget has its own recipient set.

## Configuration

The active file is reported by `openclaw config file`. The
[template](../config/openclaw.template.json) describes my setup, with placeholders
for private identifiers and credentials.
Use [OpenClaw's configuration tools](https://docs.openclaw.ai/cli/config) for
validated edits rather than replacing an existing file.

For repository-wide migration changes, personalize a copy of
`config/openclaw-quality.patch.json` first: it contains owner placeholders and
changes beyond any individual feature. It preserves existing agent identities,
workspace paths, and delegation target lists. Its browser and delegation-mode
`null` values remove overrides so the installed runtime supplies those defaults.

## Runtime updates

This custom system service uses [apply-runtime.ps1](../scripts/apply-runtime.ps1)
instead of OpenClaw's managed user-service update handoff.
Create and independently verify a current OS-disk
[recovery snapshot](backup-restore.md#create-and-verify-a-snapshot), then run
from PowerShell on your computer:

```powershell
.\scripts\apply-runtime.ps1 `
  -VmHost "<runtime-user>@<verified-host>" `
  -ResourceGroupName "<resource-group>" `
  -VerifiedSnapshotId "<succeeded-current-os-disk-snapshot-resource-id>" `
  -KeyVaultName "<vault-name>"
```

The updater verifies SSH identity and recovery evidence, stages root-owned
assets, and serializes maintenance through `/etc/openclaw/maintenance.lock`.
It prepares dependencies before stopping the Gateway, pauses the probe/snapshot
timers, then updates, validates, and starts the service. Failures after mutation
leave it stopped for operator recovery; there is no automatic package/state
rollback. Workspace templates are not applied.

The Gateway uses `Restart=always` with a thirty-second delay. An explicit stop
stays stopped; configuration exit status 78 prevents invalid-config restart loops.
If an update fails, inspect its recorded recovery artifacts and service journal
before starting again. Configuration, package, and disk rollback are different
[recovery layers](backup-restore.md).

## Infrastructure-only updates

Existing-host deployment updates monitoring and snapshot-role prerequisites
without replacing the VM, runtime, or networking:

```powershell
.\deploy.ps1 -SkipCustomData `
  -VerifiedSnapshotId "<succeeded-current-os-disk-snapshot-resource-id>" `
  -DiagnosticsContactEmails @("<diagnostics-contact>") `
  -EscalationContactEmails @("<escalation-contact>")
```

Both recipient arrays are desired-state inputs; `@()` explicitly declares none.
Subscription budget recipients use the separate subscription deployment path.

## Repository validation

```powershell
pwsh scripts/test-repository.ps1
```

Windows validation uses WSL for Linux checks. Exact-runtime tests use isolated
state, not the running installation. After editing the template, regenerate
the migration patch with `python scripts/sync-quality-patch.py`. After changing
bundled runtime assets, run `scripts/sync-cloud-init-assets.ps1`.
