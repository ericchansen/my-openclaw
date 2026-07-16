#!/usr/bin/env bash
set -Eeuo pipefail

: "${OPENCLAW_BACKUP_ACCOUNT:?OPENCLAW_BACKUP_ACCOUNT is required}"
: "${OPENCLAW_BACKUP_CONTAINER:?OPENCLAW_BACKUP_CONTAINER is required}"

usage() {
  printf 'Usage: %s <blob-name>\n' "$0" >&2
  exit 64
}

[[ $# -eq 1 && "$1" != -* ]] || usage
blob_name="$1"
command -v az >/dev/null
command -v jq >/dev/null
command -v openclaw >/dev/null
command -v python3 >/dev/null
command -v sha256sum >/dev/null
command -v sqlite3 >/dev/null
umask 077
runtime_root="${RUNTIME_DIRECTORY:-${HOME}/.cache/openclaw-restore-verify}"
mkdir -p "$runtime_root"
chmod 0700 "$runtime_root"
stage="$(mktemp -d -p "$runtime_root" verify-XXXXXXXX)"
trap 'rm -rf -- "$stage"' EXIT
bundle="$stage/bundle.tar.gz"
extract_root="$stage/extracted"
mkdir -m 0700 "$extract_root"

az login --identity --allow-no-subscriptions --output none
az storage blob download \
  --account-name "$OPENCLAW_BACKUP_ACCOUNT" \
  --container-name "$OPENCLAW_BACKUP_CONTAINER" \
  --name "$blob_name" \
  --file "$bundle" \
  --auth-mode login \
  --overwrite true \
  --no-progress \
  --only-show-errors \
  --output none

python3 - "$bundle" "$extract_root" <<'PY'
import pathlib
import sys
import tarfile

archive = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2]).resolve()
with tarfile.open(archive, "r:gz") as tf:
    for member in tf.getmembers():
        destination = (target / member.name).resolve()
        if target != destination and target not in destination.parents:
            raise SystemExit(f"unsafe archive member: {member.name}")
        if not (member.isfile() or member.isdir()):
            raise SystemExit(f"unsupported archive member: {member.name}")
    tf.extractall(target)
PY

(
  cd "$extract_root"
  [[ "$(wc -l < BUNDLE-SHA256SUMS)" -eq 2 ]]
  awk '
    $2 == "manifest.json" { manifest = 1; next }
    $2 == "SHA256SUMS" { sums = 1; next }
    { invalid = 1 }
    END { exit !(manifest && sums && !invalid) }
  ' BUNDLE-SHA256SUMS
  awk '
    $2 ~ /^native\/[^/]+\.tar\.gz$/ { native += 1; next }
    $2 == "sqlite/global.sqlite" { global = 1; next }
    $2 == "sqlite/main.sqlite" { main = 1; next }
    { invalid = 1 }
    END { exit !(native == 1 && global && main && !invalid) }
  ' SHA256SUMS
  sha256sum --check BUNDLE-SHA256SUMS
  sha256sum --check SHA256SUMS
  jq -e '
    .schemaVersion == 1 and
    ([.sqliteSnapshots[]?.role] | sort) == ["global", "main"] and
    ([.sqliteSnapshots[]?.path] | sort) == ["sqlite/global.sqlite", "sqlite/main.sqlite"]
  ' manifest.json >/dev/null
)
mapfile -t native_archives < <(find "$extract_root/native" -maxdepth 1 -type f -name '*.tar.gz' -print)
[[ ${#native_archives[@]} -eq 1 &&
  "$(find "$extract_root/native" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]] || {
  printf 'Expected one native archive, found %s\n' "${#native_archives[@]}" >&2
  exit 1
}
openclaw backup verify "${native_archives[0]}"
mapfile -d '' -t sqlite_snapshots < <(find "$extract_root/sqlite" -maxdepth 1 -type f -name '*.sqlite' -print0)
[[ ${#sqlite_snapshots[@]} -eq 2 &&
  "$(find "$extract_root/sqlite" -mindepth 1 -maxdepth 1 | wc -l)" -eq 2 &&
  -f "$extract_root/sqlite/global.sqlite" &&
  -f "$extract_root/sqlite/main.sqlite" ]] || {
  printf 'Expected exactly the global and main SQLite snapshots.\n' >&2
  exit 1
}
[[ "$stage" != *"'"* ]] || {
  printf 'Private staging path contains an unsupported quote character.\n' >&2
  exit 1
}
for role in global main; do
  snapshot="$extract_root/sqlite/${role}.sqlite"
  snapshot_integrity="$(sqlite3 -readonly "$snapshot" 'PRAGMA integrity_check;')"
  [[ "$snapshot_integrity" == ok ]] || {
    printf '%s SQLite snapshot failed integrity_check.\n' "$role" >&2
    exit 1
  }
  restored="$stage/restored-${role}.sqlite"
  sqlite3 -readonly "$snapshot" <<EOF
.timeout 30000
.backup '$restored'
EOF
  chmod 0600 "$restored"
  restored_integrity="$(sqlite3 -readonly "$restored" 'PRAGMA integrity_check;')"
  [[ "$restored_integrity" == ok && -s "$restored" ]] || {
    printf '%s SQLite restore verification failed integrity_check.\n' "$role" >&2
    exit 1
  }
done

printf '{"event":"restore_verification","result":"succeeded","productionModified":false}\n'
