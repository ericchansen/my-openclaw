# OpenClaw on Azure

Reproducible Azure VM deployment and operating model for a private OpenClaw gateway with Telegram, Discord, Azure Key Vault, Tailscale, verified Blob backups, and Azure Monitor.

## Design

- Ubuntu 24.04 ARM64 VM with a 64 GiB Standard SSD OS disk and a system-assigned managed identity
- OpenClaw gateway under systemd, bound to loopback and exposed through Tailscale Serve
- Azure Key Vault exec SecretRefs instead of plaintext config or broad environment injection
- Private Azure Blob container with managed-identity uploads
- Daily verified backups retained for 35 days and monthly backups retained for 12 months
- Structured local health checks collected by Azure Monitor/Log Analytics
- Parent-owned native OpenClaw orchestration for complex requests
- Builtin hybrid memory search using GitHub Copilot embeddings over curated private files
- GPT-5.6 Sol with high reasoning as the interactive control plane, Claude Sonnet 5 as fallback, and GPT-5.6 Luna for bounded low-risk background work

Telegram and Discord configuration is an overlay on the live VM. Deployment automation never runs onboarding or replaces a working channel configuration wholesale.

## Repository

| Path | Purpose |
|---|---|
| `infra/` | VM, identity, Key Vault, backup storage, monitoring, budget, and RBAC |
| `config/` | OpenClaw template and canonical systemd units |
| `scripts/` | Idempotent runtime install/apply, backup, restore verification, and health checks |
| `workspace/` | Concise agent contract and Copilot repository-lane skill |
| `docs/` | SecretRef, cron, orchestration, memory, benchmark, backup, and operations runbooks |
| `deploy.ps1` | Canonical Azure validation/what-if/deployment entry point |
| `migrate.ps1` | Verified backup-based migration that fails closed when restore is unsupported |

## Prerequisites

- Azure CLI authenticated to the target subscription
- Azure Bicep CLI (`az bicep version`)
- PowerShell 7
- OpenSSH client and a verified host key for existing-VM updates
- An SSH public key

Do not pass bot tokens, PATs, or API keys to deployment scripts. Put credential values in Key Vault through an approved value-safe process, then map supported fields to SecretRefs.

## Deploy Azure Resources

`deploy.ps1` is the canonical entry point. It validates and previews each resource-group or subscription deployment before applying that scope.
For a new VM, it resolves the signed-in Azure principal and grants that principal Key Vault Administrator so required secrets can be seeded; pass `-DeployerPrincipalId` when automatic resolution is unavailable. Existing-VM mode does not add that role unless explicitly requested.
Remove the deployer assignment after secrets are seeded and SecretRefs are verified unless ongoing Key Vault administration is intentional.

New VM:

```powershell
.\deploy.ps1 `
  -SshPublicKeyPath "$HOME\.ssh\id_ed25519.pub" `
  -MonitoringContactEmails "you@example.com"
```

Existing VM infrastructure update:

```powershell
.\deploy.ps1 `
  -SshPublicKeyPath "$HOME\.ssh\id_ed25519.pub" `
  -VerifiedSnapshotId "<managed-disk-snapshot-resource-id>" `
  -MonitoringContactEmails "you@example.com" `
  -SkipCustomData
```

Review the complete what-if. Stop if Azure proposes replacing the VM, OS disk, NIC, VNet, public IP, or Key Vault.
Interactive runs require separate confirmation after each scope's what-if. The script detects an existing `openclaw-vm` automatically and will not deploy until given a succeeded snapshot of its current OS disk. Existing-VM mode preserves the image version, VM size, and disk size already recorded in Azure and references the existing NSG without redeploying its rules.

`azure.yaml` describes the Bicep project for Azure Developer CLI discovery, but it does not replace the guarded deployment workflow above.

## Apply Runtime Assets to an Existing VM

After the infrastructure deployment outputs the Key Vault and storage names:

```powershell
.\scripts\apply-runtime.ps1 `
  -VmHost "azureuser@<vm-fqdn>" `
  -ResourceGroupName "rg-openclaw" `
  -VerifiedSnapshotId "<managed-disk-snapshot-resource-id>" `
  -KeyVaultName "<vault-name>" `
  -StorageAccountName "<storage-account>"
```

The script requires an existing verified SSH host key and rejects an SSH target whose Azure IMDS resource ID does not match the snapshotted VM. The installer:

- installs tested runtime versions;
- installs canonical gateway/backup/health units and scripts;
- validates an active OpenClaw config before restarting the gateway;
- prevents `needrestart` from restarting unrelated host services during package maintenance;
- merges bounded Docker logging defaults without restarting Docker;
- starts backup and health timers;
- never onboards or rewrites channels.

Apply Docker daemon changes only during an operator-controlled window, then recreate only OpenClaw-owned containers. Do not stop unrelated projects.

## Configure OpenClaw

`config/openclaw.template.json` is a schema-validated reference, not a replacement for a live config.

For an existing deployment:

1. Create and verify a backup.
2. Install the Key Vault resolver.
3. Add the exec provider and credential references through the OpenClaw secrets workflow.
4. Apply only the non-secret quality patch paths needed for the Sol/Luna model policy, pruning, planning, Tool Search, subagents, heartbeat, hybrid memory, trusted plugin allowlisting, diagnostics, and logging.
5. Validate before restart.
6. Compare sanitized before/after channel and cron structures.
7. Exercise Telegram, Discord, Gmail, model, cron, and native task handoff through their existing identities.

Never rerun onboarding to apply this repository.

See [Key Vault SecretRefs](docs/keyvault-integration.md), [Operations](docs/operations.md), and [Backup and restore](docs/backup-restore.md).

## Workspace

Copy generic templates only when creating a new workspace:

```bash
install -m 0644 workspace/AGENTS.md ~/.openclaw/workspace/AGENTS.md
install -m 0644 workspace/SOUL.template.md ~/.openclaw/workspace/SOUL.md
install -m 0644 workspace/USER.template.md ~/.openclaw/workspace/USER.md
install -m 0644 workspace/IDENTITY.template.md ~/.openclaw/workspace/IDENTITY.md
install -m 0644 workspace/HEARTBEAT.template.md ~/.openclaw/workspace/HEARTBEAT.md
install -m 0644 workspace/TOOLS.template.md ~/.openclaw/workspace/TOOLS.md
```

Do not overwrite a live private `MEMORY.md`, `USER.md`, topic memory, daily notes, skills, or channel-specific instructions. Curate those in place according to [Memory curation](docs/memory-curation.md).

## Routine Checks

```bash
curl --fail http://127.0.0.1:18789/health
openclaw config validate
openclaw doctor --lint --json
openclaw channels status --probe --json
openclaw security audit --json
openclaw secrets audit --allow-exec --check --json
openclaw tasks audit --json
systemctl status openclaw-gateway openclaw-backup.timer openclaw-health.timer
```

Monitor `/health`, not a model-backed completion endpoint.

## Documentation

- [Operations and rollback](docs/operations.md)
- [Backup and restore](docs/backup-restore.md)
- [Azure Key Vault SecretRefs](docs/keyvault-integration.md)
- [Native orchestration](docs/orchestrator-pattern.md)
- [Agent hierarchy](docs/agent-hierarchy.md)
- [Cron patterns](docs/cron-patterns.md)
- [TODO and task conventions](docs/todo-conventions.md)
- [Memory curation](docs/memory-curation.md)
- [Private quality benchmark](docs/quality-benchmark.md)

## Deferred Network Work

This pass intentionally preserves the existing public IP and SSH rule. A later change should move administration to Bastion or a Tailscale-only path and restrict the storage/Key Vault network surfaces with private endpoints or firewalls. Data remains non-anonymous and protected by Entra ID/RBAC in the current design.
