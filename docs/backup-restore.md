# Backup and Restore

OpenClaw state is backed up with two independent layers:

1. `openclaw backup create --verify` creates the supported full archive.
2. Online SQLite snapshots capture the global and main-agent databases and run `PRAGMA integrity_check`.

The backup script packages the verified artifacts, manifest, and checksums, then uploads with the VM managed identity. It never uses storage account keys.

## Schedule and Retention

`openclaw-backup.timer` runs daily. Each successful run writes:

```text
daily/YYYY/MM/DD/openclaw-<timestamp>.tar.gz
```

The first successful run in a month also creates:

```text
monthly/YYYY/MM/openclaw-YYYY-MM.tar.gz
```

If the first daily run fails, later runs continue trying to establish that month's copy. Azure lifecycle rules delete daily objects after 35 days and monthly objects after 365 days. Blob versioning, soft delete, change feed, and point-in-time restore provide additional recovery protection; this is not a legal-hold/WORM policy.

## Check Backup Health

```bash
systemctl status openclaw-backup.timer
systemctl status openclaw-backup.service
journalctl -u openclaw-backup.service --since today --no-pager
cat /var/lib/openclaw-runtime/backup-status.json | jq
```

The status file contains only timestamp, result, and checksum detail. It must not contain secret values or archive content.

List objects with managed identity:

```bash
set -a
source /etc/openclaw/runtime.env
set +a
az login --identity --allow-no-subscriptions
az storage blob list \
  --account-name "$OPENCLAW_BACKUP_ACCOUNT" \
  --container-name "$OPENCLAW_BACKUP_CONTAINER" \
  --auth-mode login \
  --query '[].{name:name,size:properties.contentLength,modified:properties.lastModified}' \
  --output table
```

## Non-Destructive Restore Verification

Choose an existing Blob name and run:

```bash
set -a
source /etc/openclaw/runtime.env
set +a
openclaw-restore-verify 'daily/YYYY/MM/DD/openclaw-<timestamp>.tar.gz'
```

The verifier:

- downloads into a private temporary directory;
- rejects unsafe archive members;
- verifies all checksums and manifests;
- runs OpenClaw archive verification;
- checks both SQLite snapshots;
- restores SQLite copies only into disposable files;
- never writes production state.

Run this after initial rollout and quarterly thereafter.

## Existing-Host Recovery Point

Before an existing-host infrastructure or runtime update, create a managed-disk snapshot and verify that it succeeded:

```bash
os_disk_id="$(az vm show \
  --resource-group rg-openclaw \
  --name openclaw-vm \
  --query storageProfile.osDisk.managedDisk.id \
  --output tsv)"
snapshot_name="openclaw-vm-os-$(date -u +%Y%m%d-%H%M%S)"
az snapshot create \
  --resource-group rg-openclaw \
  --name "$snapshot_name" \
  --source "$os_disk_id" \
  --sku Standard_LRS \
  --output none
snapshot_id="$(az snapshot show \
  --resource-group rg-openclaw \
  --name "$snapshot_name" \
  --query id \
  --output tsv)"
```

Pass `snapshot_id` to `deploy.ps1` or `apply-runtime.ps1`. Both scripts reject a snapshot that is not in `Succeeded` state or whose source is not the VM's current OS disk.

## Full Restore

OpenClaw 2026.7.1 can create and verify full archives but does not expose a supported full-archive restore command. Do not unpack an archive over a live state directory.

Until the installed version provides an official restore operation:

1. stop and preserve the affected host;
2. create another verified backup if possible;
3. restore the Azure OS-disk snapshot for whole-VM rollback, or provision a disposable recovery VM;
4. use supported OpenClaw restore tooling only after checking the installed CLI help;
5. validate config, Doctor, secrets, channels, tasks, and cron before serving traffic.

`migrate.ps1` and `migrate-restore.sh` intentionally fail with exit 78 when no supported full restore exists. The verified archive remains available; failure must never trigger an ad-hoc destructive extraction.

## Recovery Evidence

Record, without secret values:

- archive/Blob name and checksum;
- OpenClaw version;
- snapshot timestamp and Azure resource ID;
- verification command and exit status;
- restored disposable SQLite integrity result;
- production channel/cron checks after a real rollback.

Treat archives, disk snapshots, manifests, and diagnostic bundles as sensitive because they can contain credentials, private conversations, and memory.
