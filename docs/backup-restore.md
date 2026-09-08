# Backup and restore

The [backup helper](../scripts/openclaw-backup.sh) bundles a verified native
`openclaw backup create --verify` archive with owner-aware SQLite snapshots of
shared state and every initialized configured agent database. Checksums and a
manifest accompany managed-identity Blob uploads; storage account keys are not used.
Use the exact [runtime pins](../config/runtime-versions.json) and
[official backup CLI](https://github.com/openclaw/openclaw/blob/v2026.9.2/docs/cli/backup.md).

## Coverage and scheduling

SQLite snapshots use the backup API to include committed WAL state without
copying live databases or their `-wal`/`-shm` sidecars. An uninitialized agent is
recorded as `database-not-found`; an existing inaccessible/corrupt database fails
the backup. Inspect coverage in the manifest rather than assuming all agents ran.

Native archives exclude some session/cron `.jsonl`/`.log` and log-directory files.
Canonical current transcripts are covered by agent SQLite snapshots; excluded
legacy/completed files are not a portable-recovery guarantee. For complete
filesystem recovery, stop the Gateway and quiesce other writers before taking a
disk/filesystem snapshot. Do not copy excluded live files piecemeal.

The timer runs daily. [Storage lifecycle rules](../infra/main.bicep) retain
`daily/YYYY/MM/DD/` objects for 35 days and `monthly/YYYY/MM/` for 365 days.
The first successful daily run each month establishes the monthly copy.
Versioning/soft delete add protection, not a legal-hold or WORM guarantee.

Backup holds a shared [maintenance lock](operations.md#stable-updates) throughout.
Contention emits `backup_skipped` without replacing the last backup status.
A missing/unsafe lock is an error; never delete it or run unlocked.

## Check and rehearse recovery

```bash
systemctl status openclaw-backup.timer openclaw-backup.service
journalctl -u openclaw-backup.service --since today --no-pager
cat /var/lib/openclaw-runtime/backup-status.json | jq
set -a
source /etc/openclaw/runtime.env
set +a
openclaw-restore-verify 'daily/YYYY/MM/DD/openclaw-<timestamp>.tar.gz'
```

Choose an existing Blob. The [verifier](../scripts/openclaw-restore-verify.sh)
uses private staging, rejects unsafe archive members, checks manifests/checksums,
verifies native and SQLite artifacts, and rehearses native restore into a fresh
tree. It never activates or writes production state. Rehearse after rollout and
periodically thereafter; keep all archive/diagnostic content private.

## Pre-change recovery point

Before existing-host infrastructure or runtime changes:

1. As the runtime user, create and retain a verified native archive:
   `openclaw backup create --output <protected-backup-directory> --verify`.
2. Identify the VM's current OS managed disk and create a
   [managed-disk snapshot](https://learn.microsoft.com/en-us/azure/virtual-machines/snapshot-copy-managed-disk).
   Quiesce writers first when an application-consistent rollback is required.
3. Confirm snapshot provisioning is `Succeeded` and its source is that current
   OS disk; record its resource ID, timestamp, archive checksum, and runtime version.
4. Pass the snapshot ID to [deploy.ps1](../deploy.ps1) or
   [apply-runtime.ps1](../scripts/apply-runtime.ps1); runtime apply also needs the
   native archive path, **not** the outer Blob bundle. Both guard snapshot provenance.
   Existing-host deployment refreshes monitoring only; runtime application is separate.

For an older archive rejected because of derived absolute plugin/npm symlinks,
stop the Gateway and use [openclaw-migration-backup.sh](../scripts/openclaw-migration-backup.sh).
It handles only recognized derived links and restores them; unknown links fail
closed. Preserve the quiesced disk snapshot as the complete rollback source.

## Staged restore and activation

```bash
openclaw backup restore <native-archive.tar.gz> --target <fresh-staging-directory>
```

Never target live state or unpack the outer bundle over it.
[migrate.ps1](../migrate.ps1) requires the source Gateway stopped and RPC unreachable
before and after archive creation. It and [migrate-restore.sh](../scripts/migrate-restore.sh)
only stage recovery; they do not stop/start services or activate restored state.

Keep the Gateway offline while verifying staging ownership/modes, configuration,
and each shared/agent SQLite snapshot. Preserve the current tree, restore the
intended compatible database snapshots using the installed backup CLI, and
atomically select the recovered tree through an operator-reviewed procedure.
Validate configuration and run Doctor before one start. Check exact running
version, real channels/tools, automations/tasks, and backup/health timers.

## Rollback layers

- **Code:** install the reviewed exact prior package and repair/validate offline.
- **State:** restore into a fresh tree and activate offline; never merge into live state.
- **Disk:** preserve the failed disk, recover from the succeeded snapshot, and validate privately.

A package downgrade does **not** downgrade SQLite schemas. Restore compatible
pre-upgrade shared and agent/session database snapshots before starting older
code; otherwise remain stopped. Preserve archive checksum, snapshot provenance,
verification results, and post-recovery channel checks without secret values.
Archives, manifests, snapshots, and diagnostics can contain private conversations
or credentials. Never rerun onboarding or broaden network access to recover.
