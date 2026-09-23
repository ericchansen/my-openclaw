# Backup and restore readiness

The supported recovery mechanism is the Azure managed OS-disk snapshot timer,
`openclaw-vm-snapshot.timer`, scheduled daily with a fixed 05:30 UTC anchor and
bounded jitter. The service discovers the current VM OS disk at runtime, creates
an incremental snapshot, independently reads it back, verifies `Succeeded`, the
source disk, incrementality, ownership tags, and retains exactly the newest
seven names in its own `openclaw-auto-daily-YYYYMMDDTHHMMSSZ` namespace.

Snapshots are crash-consistent whole-OS-disk recovery points. A non-destructive
restore-readiness proof consists of inspecting the snapshot metadata and source
OS-disk ID, confirming `Succeeded`/incremental/tags, and recording the exact
restore drill: create a managed disk from a selected snapshot in the same
region, attach it to a disposable test VM or recovery VM, validate the expected
filesystem and OpenClaw configuration read-only, then discard only the test
resources. Never replace or boot the production VM as part of routine proof.

Application-level Blob archive backup is not deployed. Small OpenClaw config
`.bak*` undo files remain local bounded safety aids and are not a backup system.
