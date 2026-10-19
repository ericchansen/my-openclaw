# Azure snapshot recovery

This installation creates incremental managed OS-disk snapshots daily at
05:30 UTC with up to fifteen minutes of fixed jitter. It retains the newest
three succeeded snapshots in its own `openclaw-auto-daily-YYYYMMDDTHHMMSSZ`
namespace. These are crash-consistent disk recovery points, not application
exports. There is no deployed Blob archive or separate SQLite backup schedule.

## Create and verify a snapshot

Before changing infrastructure or runtime, record the repository commit and,
on the VM, run:

```bash
sudo systemctl start openclaw-vm-snapshot.service
sudo journalctl -u openclaw-vm-snapshot.service -n 30 --no-pager
sudo cat /var/lib/openclaw-vm-snapshot/last-created.json
```

From an independently authenticated Azure CLI on your computer, compare the
current OS disk with the snapshot's source:

```powershell
az vm show -g "<resource-group>" -n "<vm-name>" `
  --query storageProfile.osDisk.managedDisk.id -o tsv
az snapshot show --ids "<snapshot-resource-id>" `
  --query "{state:provisioningState,incremental:incremental,source:creationData.sourceResourceId,tags:tags}" -o json
```

Require `Succeeded`, `incremental: true`, the current OS-disk source, and ownership
tags `purpose=openclaw-automated-backup`, `createdBy=openclaw-vm-snapshot`,
`retention=3`. Pass that exact snapshot resource ID to the update command.

## Recover to a separate disk

Select a verified snapshot and create a new disk in its region:

```powershell
az disk create --resource-group "<recovery-resource-group>" `
  --name "<new-recovery-disk-name>" --location "<snapshot-region>" `
  --source "<snapshot-resource-id>" --query id -o tsv
az vm disk attach --resource-group "<recovery-resource-group>" `
  --vm-name "<recovery-vm-name>" --name "<new-recovery-disk-resource-id>"
```

Use a separate recovery VM, not the running OpenClaw VM. Follow
[Azure's Linux disk recovery procedure](https://learn.microsoft.com/troubleshoot/azure/virtual-machines/linux/troubleshoot-recovery-disks-portal-linux)
to identify and inspect the attached filesystem read-only. Check:

- `/home/azureuser/.openclaw` for configuration, agent state, and workspace data;
- `/etc/openclaw` and `/etc/systemd/system/openclaw-*` for deployed service settings;
- package versions against the repository commit recorded with the snapshot.

The recovered disk contains credentials and private conversations. Keep access
restricted. Replacing production's OS disk or booting the recovered installation
is a separate cutover: stop competing channel/scheduler instances and verify the
intended disk before switching. A read-only inspection does not itself restore service.

## Other rollback layers

Configuration/unit rollback restores the specific previous files and ownership,
validates configuration, and restarts the affected service. Package rollback
must account for state/schema changes; downgrading a package does not undo them.
Whole-disk recovery is the fallback when files and runtime state need to move
together. Native OpenClaw export/import operations are documented
[upstream](https://docs.openclaw.ai/cli/backup).
