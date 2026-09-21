# Verified backup retention

This repository owns the backup storage account's lifecycle policy. Deployments replace the policy declaratively; operators must review unrelated rules before applying a changed template.

## Controls

- `openclaw-backup.service` runs the verified native/SQLite application backup nightly. Housekeeping is a required successful predecessor and enforces 8 GiB free plus `<85%` root use after bounded cleanup.
- The post-success drop-in computes an exact inventory plan, retains newest 7 `daily/` and newest 2 `monthly/` objects, deletes exact names only, and verifies the final inventory.
- `openclaw-vm-snapshot.timer` creates a weekly incremental snapshot from the current VM OS disk, verifies source/state/incremental/tags, then retains only the newest 2 exact automated names.
- Azure Blob versioning/soft delete are 7 days; the container-scoped lifecycle rule removes prior versions and snapshots after 7 days.
- The VM system-assigned identity receives container-scoped Blob Data Contributor and resource-group-scoped snapshot plus Reader roles. No keys or secrets are in source.

The Bicep parameters `dailyBackupRetention`, `monthlyBackupRetention`, and `weeklySnapshotRetention` default to 7, 2, and 2. Cloud-init passes them to the runtime installer, which writes non-secret values and the configured runtime user/home into `/etc/openclaw/runtime.env`; the housekeeping, Blob-pruning, and snapshot units consume that file.

## Rollout

Run `deploy.ps1` through its existing what-if and snapshot guard. For a new VM, cloud-init installs and enables the scripts, units, timers, and backup drop-ins. Existing hosts use the guarded runtime application path; do not copy `runtime.env` into source.

Validate with `bash -n`, `systemd-analyze verify`, `scripts/sync-cloud-init-assets.ps1 -Check`, `az bicep build`, and repository tests. Confirm timers, a housekeeping dry run, a backup dry run/verified status, and snapshot readback before treating the rollout as complete.

## Restore and rollback

For application restore, use `/usr/local/sbin/openclaw-restore-verify` and restore to a private staging path before any maintenance-locked cutover. Blob soft-delete/version recovery is available during its seven-day window. VM snapshots are crash-consistent and should be restored to a separately reviewed disk/VM. Roll back source by reverting the deployment commit and rerunning the guarded what-if; never delete unrelated blobs or snapshots.

## Retired legacy backup

The retired local cron/archive mechanism is intentionally absent: no `/usr/local/bin/openclaw-backup`, legacy local backup roots, or cron dependency is installed by this repository. The bounded `openclaw.json.bak*` configuration-copy policy is unrelated and remains outside this backup system.
