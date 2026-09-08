#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 2 ]] || {
  printf 'Usage: %s <verified-backup-archive> <fresh-staging-directory>\n' "$0" >&2
  exit 64
}
archive="$1"
target="$2"
[[ -f "$archive" && ! -L "$archive" ]] || exit 66
[[ ! -e "$target" ]] || {
  printf 'Restore target must not already exist: %s\n' "$target" >&2
  exit 73
}
umask 077

openclaw backup restore --help >/dev/null 2>&1 || {
  printf 'This OpenClaw version lacks native staged backup restore.\n' >&2
  exit 78
}
openclaw backup verify "$archive"
openclaw backup restore "$archive" --target "$target" --json
[[ -d "$target" ]]
printf '%s\n' \
  "Verified backup restored to fresh staging: $target" \
  'Production state was not modified. Activate only while the Gateway is offline.'
