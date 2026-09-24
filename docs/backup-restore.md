# Backup and restore readiness

## Pre-change recovery point

Before an existing-host infrastructure or runtime change, retain the reviewed
source/IaC commit and create a succeeded snapshot of the current VM OS disk.
Pass that exact snapshot resource ID to the guarded deployment or runtime
update. Do not use a Blob backup service or invent an application-backup
schedule.

The supported recovery mechanism is the Azure managed OS-disk snapshot timer,
`openclaw-vm-snapshot.timer`, scheduled daily with a fixed 05:30 UTC anchor and
bounded jitter. The service discovers the current VM OS disk at runtime, creates
an incremental snapshot, independently reads it back, verifies `Succeeded`, the
source disk, incrementality, ownership tags, and retains exactly the newest
three names in its own `openclaw-auto-daily-YYYYMMDDTHHMMSSZ` namespace.

Snapshots are crash-consistent whole-OS-disk recovery points. A non-destructive
restore-readiness proof consists of inspecting the snapshot metadata and source
OS-disk ID, confirming `Succeeded`/incremental/tags, and recording the exact
restore drill: create a managed disk from a selected snapshot in the same
region, attach it to a disposable test VM or recovery VM, validate the expected
filesystem and OpenClaw configuration read-only, then discard only the test
resources. Never replace or boot the production VM as part of routine proof.

Application-level Blob archive backup is not deployed. Small OpenClaw config
`.bak*` undo files remain local bounded safety aids and are not a backup system.

## Rollback layers

- **Configuration and IaC:** restore the reviewed Git commit or exact staged
  runtime files, then validate before restarting the Gateway.
- **Package/runtime:** use the guarded updater recovery evidence; it leaves the
  Gateway stopped after a failed validation rather than guessing a rollback.
- **Machine state:** create a managed disk from a selected succeeded snapshot
  in the same region, attach it to a disposable recovery VM, validate the
  expected filesystem and OpenClaw configuration read-only, and replace or
  restore production only through an explicit reviewed recovery operation.

Snapshots are crash-consistent recovery points, not a substitute for testing a
restore. No automated SQLite or Blob backup service is part of the declared
runtime.
