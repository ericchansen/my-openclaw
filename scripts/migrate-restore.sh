#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 1 ]] || {
  printf 'Usage: %s <verified-backup-archive>\n' "$0" >&2
  exit 64
}
archive="$1"
[[ -f "$archive" ]] || exit 66
umask 077

openclaw backup verify "$archive"
pre_restore_root="${HOME}/.cache/openclaw-migration/pre-restore"
mkdir -p "$pre_restore_root"
chmod 0700 "${HOME}/.cache/openclaw-migration" "$pre_restore_root"
pre_restore_dir="$(mktemp -d -p "$pre_restore_root" run-XXXXXXXX)"
chmod 0700 "$pre_restore_dir"
openclaw backup create --output "$pre_restore_dir" --verify
mapfile -t pre_restore_archives < <(
  find "$pre_restore_dir" -maxdepth 1 -type f -name '*.tar.gz' -print
)
[[ ${#pre_restore_archives[@]} -eq 1 ]] || {
  printf 'Expected exactly one pre-restore archive, found %s.\n' \
    "${#pre_restore_archives[@]}" >&2
  exit 1
}
pre_restore_archive="${pre_restore_archives[0]}"
openclaw backup verify "$pre_restore_archive"

restore_mode=
if openclaw backup restore --help >/dev/null 2>&1; then
  restore_mode=backup
elif openclaw restore --help >/dev/null 2>&1; then
  restore_mode=legacy
else
  printf '%s\n' \
    'This OpenClaw version can verify full backups but has no supported full-backup restore command.' \
    "Verified archive retained at: $archive" >&2
  exit 78
fi

sudo systemctl stop openclaw-gateway.service
leave_gateway_stopped() {
  local code=$?
  trap - EXIT
  printf '%s\n' \
    'Restore or post-restore validation failed; the gateway remains stopped.' \
    "Verify and restore the pre-restore archive before restarting: $pre_restore_archive" >&2
  exit "$code"
}
trap leave_gateway_stopped EXIT
if [[ "$restore_mode" == backup ]]; then
  openclaw backup restore "$archive"
else
  openclaw restore "$archive"
fi
timeout --signal=TERM --kill-after=5s 60s openclaw doctor --lint --json >/dev/null
sudo systemctl start openclaw-gateway.service
trap - EXIT
printf 'Verified OpenClaw backup restored successfully.\n'
