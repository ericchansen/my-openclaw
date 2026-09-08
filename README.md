# OpenClaw on Azure

Reproducible Azure VM deployment for a private OpenClaw gateway with Telegram,
Discord, Key Vault SecretRefs, verified Blob backups, and Azure Monitor.

The runtime is the unmodified official OpenClaw **2026.9.2** on Node **22.23.1**.
[Runtime versions and integrity pins](config/runtime-versions.json) are authoritative;
do not substitute an experimental distribution or a mutable package tag.
Production uses [GPT-6 Astra through the official Copilot harness](docs/astra-model.md),
with native Sonnet 5 fallback. The default template remains a valid Sonnet baseline
until the official plugin and CLI-path prerequisites are installed.

## Operating boundaries

- Systemd owns the Gateway, backup/health timers, and local OTel collector.
- The Gateway binds to loopback; remote access requires authenticated, reviewed routing.
- Existing channels, identities, approved family routing, credentials, and data are preserved.
- Owner administration is separate from explicitly approved trusted-family sharing.
- Non-family/default isolation requires separate agents/workspaces, not just session keys.
- Current metadata telemetry and its collector are deployed dependencies; keep them.
- Future private-endpoint/NAT and public-IP cutover work is deferred, **not live**.

See the [security model](docs/security-model.md) for trust boundaries and residual risks.
Do not rerun onboarding or replace a working configuration with the reference template.
Family migration tooling is deferred; future identity/sharing changes require explicit review.

## Prerequisites

Use Azure CLI authenticated to the intended subscription, Bicep CLI, and PowerShell 7.
New VMs need an SSH public key; existing-host runtime application needs OpenSSH/Tailscale
and a separately verified SSH host key. Windows unit checks require WSL with
`systemd-analyze`; see [validation](docs/operations.md#validation).

Never pass bot tokens, PATs, or API keys to deployment scripts. Seed credentials
through an approved value-safe Key Vault process and configure
[SecretRefs](docs/keyvault-integration.md).

## Deploy infrastructure

[deploy.ps1](deploy.ps1) validates and previews each deployment scope before applying it.
For a new VM:

```powershell
.\deploy.ps1 -SshPublicKeyPath "$HOME\.ssh\id_ed25519.pub"
```

Review the what-if and confirm before applying. New-host mode grants Key Vault
administration for secret seeding; remove that deployer assignment afterward
unless continued administration is intentional. Regenerate changed cloud-init with
[`scripts/sync-cloud-init-assets.ps1`](scripts/sync-cloud-init-assets.ps1) first.
New VMs retain [baseline public networking](infra/main.bicep), not a private-network cutover.

Existing-host infrastructure updates require a succeeded snapshot of the current
OS disk; obtain and retain it using [the recovery procedure](docs/backup-restore.md#pre-change-recovery-point).

```powershell
.\deploy.ps1 -SkipCustomData `
  -VerifiedSnapshotId "<succeeded-current-os-disk-snapshot-resource-id>"
```

Existing-host mode uses [main-existing.bicep](infra/main-existing.bicep) to refresh
**monitoring only**, through the [shared monitoring module](infra/monitoring.bicep).
VM, Key Vault, and storage are existing references; VM-model, NIC, VNet, vault,
storage, and OpenClaw runtime changes are excluded. Runtime updates use the
separate guarded application below; private-network cutover remains future work.

## Apply runtime assets

Create a verified native backup on the host and retain its resulting archive path:

```bash
install -d -m 0700 "$HOME/backups/pre-update"
openclaw backup create --output "$HOME/backups/pre-update" --verify
```

Then use the guarded [runtime application script](scripts/apply-runtime.ps1):

```powershell
.\scripts\apply-runtime.ps1 `
  -VmHost "<runtime-user>@<verified-host>" `
  -ResourceGroupName "<resource-group>" `
  -VerifiedSnapshotId "<succeeded-current-os-disk-snapshot-resource-id>" `
  -VerifiedBackupArchive "<absolute-on-host-native-archive-path>" `
  -KeyVaultName "<vault-name>" -StorageAccountName "<storage-account>"
```

Supply the native archive, not the outer Blob bundle. The script verifies host
identity, snapshot provenance, and backup evidence before the maintenance-locked
update. Failures after mutation stay offline; follow
[operations and rollback](docs/operations.md), not a bare global npm update.
Use `-UseTailscaleSsh` only after tailnet enrollment and SSH authorization are verified.

## Operator references

- [Operations, health, and safe changes](docs/operations.md)
- [Availability acceptance and known limitations](docs/availability-recovery.md)
- [Backup, staged restore, and rollback](docs/backup-restore.md)
- [Security and trusted-family boundaries](docs/security-model.md)
- [Astra production overlay](docs/astra-model.md)
- [Key Vault integration](docs/keyvault-integration.md) and [telemetry privacy](docs/telemetry-privacy.md)

The [workspace templates](workspace/) are for new workspaces only. Never overwrite
live private memory, user files, skills, or channel instructions with generic examples.
