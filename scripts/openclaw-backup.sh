#!/usr/bin/env bash
set -Eeuo pipefail

: "${OPENCLAW_BACKUP_ACCOUNT:?OPENCLAW_BACKUP_ACCOUNT is required}"
: "${OPENCLAW_BACKUP_CONTAINER:?OPENCLAW_BACKUP_CONTAINER is required}"

umask 077
runtime_root="${OPENCLAW_BACKUP_WORKDIR:-${STATE_DIRECTORY:-/var/lib/openclaw-runtime}/backup-work}"
mkdir -p "$runtime_root"
chmod 0700 "$runtime_root"
lock_file="$runtime_root/backup.lock"
exec 9>"$lock_file"
flock -n 9 || {
  printf '%s\n' '{"event":"backup_skipped","reason":"already_running"}'
  exit 0
}

status_file="${STATE_DIRECTORY:-/var/lib/openclaw-runtime}/backup-status.json"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
stage="$(mktemp -d -p "$runtime_root" "stage-${stamp}-XXXXXXXX")"
mkdir -p "$stage/native" "$stage/sqlite" "$(dirname "$status_file")"
chmod 0700 "$stage" "$stage/native" "$stage/sqlite"

write_status() {
  local result="$1" detail="$2"
  jq -nc \
    --arg event backup \
    --arg result "$result" \
    --arg detail "$detail" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{event:$event,result:$result,detail:$detail,timestamp:$timestamp}' \
    > "${status_file}.new"
  chmod 0600 "${status_file}.new"
  mv -f -- "${status_file}.new" "$status_file"
}

cleanup() {
  local code=$?
  trap - EXIT
  rm -rf -- "$stage"
  if [[ -n "${bundle:-}" ]]; then
    rm -f -- "$bundle" "${bundle}.sha256"
  fi
  if (( code != 0 )); then
    set +e
    write_status failed "backup command failed"
    logger -t openclaw-backup -p local6.err \
      '{"event":"backup","result":"failed","detail":"backup command failed"}'
  fi
  exit "$code"
}
trap cleanup EXIT

command -v openclaw >/dev/null
command -v az >/dev/null
command -v jq >/dev/null
command -v sha256sum >/dev/null
command -v sqlite3 >/dev/null

openclaw backup create --output "$stage/native" --verify
mapfile -t native_archives < <(find "$stage/native" -maxdepth 1 -type f -name '*.tar.gz' -print)
[[ ${#native_archives[@]} -eq 1 ]] || {
  printf 'Expected exactly one native OpenClaw archive, found %s\n' "${#native_archives[@]}" >&2
  exit 1
}
openclaw backup verify "${native_archives[0]}"

home_root="$(realpath -e "$HOME")"
[[ "$stage" != *"'"* ]] || {
  printf 'Private staging path contains an unsupported quote character.\n' >&2
  exit 1
}

snapshot_sqlite() {
  local label="$1" relative_source="$2"
  local expected_source="$home_root/$relative_source"
  local source destination integrity
  [[ -f "$expected_source" && ! -L "$expected_source" ]] || {
    printf 'Required %s SQLite database is missing or is a symlink: %s\n' \
      "$label" "$expected_source" >&2
    return 1
  }
  source="$(realpath -e "$expected_source")"
  [[ "$source" == "$expected_source" ]] || {
    printf 'Refusing non-canonical %s SQLite path: %s\n' "$label" "$expected_source" >&2
    return 1
  }
  [[ "$(stat -c '%u' "$source")" == "$(id -u)" ]] || {
    printf 'Refusing %s SQLite database not owned by the runtime user.\n' "$label" >&2
    return 1
  }
  destination="$stage/sqlite/${label}.sqlite"
  sqlite3 -readonly "$source" <<EOF
.timeout 30000
.backup '$destination'
EOF
  sqlite3 "$destination" <<'EOF' >/dev/null
PRAGMA wal_checkpoint(TRUNCATE);
PRAGMA journal_mode=DELETE;
EOF
  rm -f -- "${destination}-shm" "${destination}-wal"
  chmod 0600 "$destination"
  integrity="$(sqlite3 -readonly "$destination" 'PRAGMA integrity_check;')"
  [[ "$integrity" == ok ]] || {
    printf '%s SQLite snapshot failed integrity_check.\n' "$label" >&2
    return 1
  }
}

# QMD/orchestrator indexes remain rebuildable and are intentionally not duplicated here.
snapshot_sqlite global '.openclaw/state/openclaw.sqlite'
snapshot_sqlite main '.openclaw/agents/main/agent/openclaw-agent.sqlite'

(
  cd "$stage"
  find native sqlite -type f -print0 |
    sort -z |
    xargs -0 sha256sum > SHA256SUMS
  jq -nc \
    --arg createdAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg openclawVersion "$(openclaw --version 2>/dev/null | head -n 1)" \
    --arg nativeArchive "$(basename "${native_archives[0]}")" \
    --arg globalSha256 "$(sha256sum sqlite/global.sqlite | cut -d' ' -f1)" \
    --arg mainSha256 "$(sha256sum sqlite/main.sqlite | cut -d' ' -f1)" \
    --argjson globalSizeBytes "$(stat -c '%s' sqlite/global.sqlite)" \
    --argjson mainSizeBytes "$(stat -c '%s' sqlite/main.sqlite)" \
    '{schemaVersion:1,createdAt:$createdAt,openclawVersion:$openclawVersion,nativeArchive:$nativeArchive,sqliteSnapshots:[
      {role:"global",path:"sqlite/global.sqlite",sha256:$globalSha256,sizeBytes:$globalSizeBytes},
      {role:"main",path:"sqlite/main.sqlite",sha256:$mainSha256,sizeBytes:$mainSizeBytes}
    ]}' \
    > manifest.json
  sha256sum manifest.json SHA256SUMS > BUNDLE-SHA256SUMS
)

bundle="$runtime_root/openclaw-${stamp}.tar.gz"
tar --create --gzip --file "$bundle" --directory "$stage" \
  manifest.json BUNDLE-SHA256SUMS SHA256SUMS native sqlite
bundle_sha="$(sha256sum "$bundle" | cut -d' ' -f1)"
printf '%s  %s\n' "$bundle_sha" "$(basename "$bundle")" > "${bundle}.sha256"
(
  cd "$runtime_root"
  sha256sum --check "$(basename "${bundle}.sha256")"
)

az login --identity --allow-no-subscriptions --output none
upload_blob() {
  local name="$1"
  az storage blob upload \
    --account-name "$OPENCLAW_BACKUP_ACCOUNT" \
    --container-name "$OPENCLAW_BACKUP_CONTAINER" \
    --name "$name" \
    --file "$bundle" \
    --auth-mode login \
    --overwrite false \
    --no-progress \
    --only-show-errors \
    --output none
}

upload_blob "daily/$(date -u +%Y/%m/%d)/$(basename "$bundle")"
monthly_name="monthly/$(date -u +%Y/%m)/openclaw-$(date -u +%Y-%m).tar.gz"
monthly_exists="$(az storage blob exists \
  --account-name "$OPENCLAW_BACKUP_ACCOUNT" \
  --container-name "$OPENCLAW_BACKUP_CONTAINER" \
  --name "$monthly_name" \
  --auth-mode login \
  --only-show-errors \
  --query exists \
  --output tsv)"
monthly_exists="${monthly_exists,,}"
if [[ "$monthly_exists" == false ]]; then
  upload_blob "$monthly_name"
elif [[ "$monthly_exists" != true ]]; then
  printf 'Could not determine whether the monthly backup exists.\n' >&2
  exit 1
fi

write_status succeeded "$bundle_sha"
logger -t openclaw-backup -p local6.notice \
  '{"event":"backup","result":"succeeded","detail":"verified and uploaded"}'
