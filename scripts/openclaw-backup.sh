#!/usr/bin/env bash
set -Eeuo pipefail

: "${OPENCLAW_BACKUP_ACCOUNT:?OPENCLAW_BACKUP_ACCOUNT is required}"
: "${OPENCLAW_BACKUP_CONTAINER:?OPENCLAW_BACKUP_CONTAINER is required}"

umask 077
maintenance_lock=/etc/openclaw/maintenance.lock
[[ -f "$maintenance_lock" && ! -L "$maintenance_lock" &&
  "$(stat -c '%u:%g:%a:%h' "$maintenance_lock")" == 0:0:644:1 ]] || {
  printf 'OpenClaw maintenance lock is missing or unsafe.\n' >&2
  exit 78
}
exec 8<"$maintenance_lock"
flock --shared --nonblock --conflict-exit-code 75 8 || {
  lock_status=$?
  (( lock_status == 75 )) || exit "$lock_status"
  printf '%s\n' '{"event":"backup_skipped","reason":"maintenance"}'
  exit 0
}
runtime_root="${OPENCLAW_BACKUP_WORKDIR:-${STATE_DIRECTORY:-/var/lib/openclaw-runtime}/backup-work}"
mkdir -p "$runtime_root"
chmod 0700 "$runtime_root"
exec 9>"$runtime_root/backup.lock"
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
  local result="$1" detail="$2" skipped_uninitialized_agents="${3:-[]}"
  jq -nc \
    --arg result "$result" --arg detail "$detail" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson skippedUninitializedAgents "$skipped_uninitialized_agents" \
    '{event:"backup",result:$result,detail:$detail,timestamp:$timestamp,
      skippedUninitializedAgents:$skippedUninitializedAgents}' \
    > "${status_file}.new"
  chmod 0600 "${status_file}.new"
  mv -f -- "${status_file}.new" "$status_file"
}

cleanup() {
  local code=$?
  trap - EXIT
  rm -rf -- "$stage"
  [[ -z "${bundle:-}" ]] || rm -f -- "$bundle" "${bundle}.sha256"
  if (( code != 0 )); then
    set +e
    write_status failed "backup command failed" "${skipped_uninitialized_agents:-[]}"
    logger -t openclaw-backup -p local6.err \
      '{"event":"backup","result":"failed","detail":"backup command failed"}'
  fi
  exit "$code"
}
trap cleanup EXIT

for command in openclaw az base64 jq python3 sha256sum; do
  command -v "$command" >/dev/null
done
openclaw backup sqlite create --help >/dev/null

native_create_json="$(openclaw backup create --output "$stage/native" --verify --json)"
if ! jq -e '
  type == "object" and
  (.archivePath | type == "string" and length > 0) and
  .verified == true and
  (.skippedVolatileCount | type == "number" and . >= 0 and floor == .)
' >/dev/null <<<"$native_create_json"; then
  printf 'Native OpenClaw backup returned an unsupported result.\n' >&2
  exit 1
fi
native_archive="$(realpath -e "$(jq -er '.archivePath' <<<"$native_create_json")")"
[[ "$native_archive" == "$stage/native/"* ]] || {
  printf 'Native OpenClaw backup returned an archive outside the private staging directory.\n' >&2
  exit 1
}
native_verify_json="$(openclaw backup verify "$native_archive" --json)"
if ! jq -e --arg archive "$native_archive" '
  type == "object" and .ok == true and .archivePath == $archive and
  (.archiveRoot | type == "string" and length > 0) and
  (.createdAt | type == "string" and length > 0) and
  (.runtimeVersion | type == "string" and length > 0) and
  (.assetCount | type == "number" and . >= 1 and floor == .) and
  (.entryCount | type == "number" and . >= 1 and floor == .) and
  (.symlinkCount | type == "number" and . >= 0 and floor == .)
' >/dev/null <<<"$native_verify_json"; then
  printf 'Native OpenClaw backup verification returned an unsupported result.\n' >&2
  exit 1
fi
native_skipped_volatile_count="$(jq -er '.skippedVolatileCount' <<<"$native_create_json")"

snapshot_index='[]'
skipped_uninitialized_agents='[]'
create_sqlite_snapshot() {
  local role="$1" agent_id="${2:-}" output snapshot canonical relative verify_output snapshot_id create_manifest
  if [[ "$role" == global ]]; then
    output="$(openclaw backup sqlite create \
      --global --repository "$stage/sqlite" --json)"
  else
    output="$(openclaw backup sqlite create \
      --agent "$agent_id" --repository "$stage/sqlite" --json)"
  fi
  if ! jq -e --arg role "$role" --arg agent "$agent_id" '
    type == "object" and .ok == true and
    (.snapshotPath | type == "string" and length > 0) and
    (.manifest | type == "object") and
    .manifest.schemaVersion == 1 and
    (.manifest.snapshotId | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$")) and
    (.manifest.createdAt | type == "string" and length > 0) and
    (.manifest.database | type == "object") and
    .manifest.database.role == $role and
    (if $role == "agent" then .manifest.database.agentId == $agent else true end) and
    (.manifest.database.basename | type == "string" and length > 0) and
    (.manifest.database.userVersion | type == "number" and floor == .) and
    (.manifest.artifact | type == "object") and
    .manifest.artifact.path == "database.sqlite" and
    (.manifest.artifact.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.manifest.artifact.sizeBytes | type == "number" and . > 0 and floor == .)
  ' >/dev/null <<<"$output"; then
    printf 'SQLite backup returned an unsupported result for %s.\n' "$role" >&2
    exit 1
  fi
  snapshot="$(jq -er '.snapshotPath' <<<"$output")"
  canonical="$(realpath -e "$snapshot")"
  [[ -d "$canonical" && "$canonical" == "$stage/sqlite/"* ]] || {
    printf 'SQLite snapshot escaped the private repository for %s.\n' "$role" >&2
    exit 1
  }
  snapshot_id="$(jq -er '.manifest.snapshotId' <<<"$output")"
  create_manifest="$(jq -c '.manifest' <<<"$output")"
  [[ "$(basename "$canonical")" == "$snapshot_id" ]] || {
    printf 'SQLite backup returned an inconsistent snapshot identifier for %s.\n' "$role" >&2
    exit 1
  }
  verify_output="$(openclaw backup sqlite verify "$canonical" --json)"
  if ! jq -e --arg path "$canonical" --argjson expected "$create_manifest" '
    type == "object" and .ok == true and .snapshotPath == $path and
    .manifest == $expected
  ' >/dev/null <<<"$verify_output"; then
    printf 'SQLite backup verification returned an unsupported result for %s.\n' "$role" >&2
    exit 1
  fi
  relative="${canonical#"$stage/"}"
  snapshot_index="$(
    jq -c --arg role "$role" --arg agentId "$agent_id" --arg path "$relative" \
      '. + [{role:$role,path:$path} + if $agentId == "" then {} else {agentId:$agentId} end]' \
      <<<"$snapshot_index"
  )"
}

create_sqlite_snapshot global
agents_json="$(openclaw agents list --json)"
if ! jq -e '
  type == "array" and length > 0 and
  all(.[]; type == "object" and
    (.id | type == "string" and test("^[A-Za-z0-9_][A-Za-z0-9_-]{0,63}$")) and
    (.agentDir | type == "string" and startswith("/")) and
    (.workspace | type == "string" and startswith("/")) and
    (.bindings | type == "number" and . >= 0 and floor == .) and
    (.isDefault | type == "boolean")) and
  ([.[].id] | unique | length) == length
' >/dev/null <<<"$agents_json"; then
  printf 'OpenClaw agents list returned an unsupported result.\n' >&2
  exit 1
fi
mapfile -t agent_records < <(
  jq -cr 'sort_by(.id)[] | @base64' <<<"$agents_json"
)
[[ ${#agent_records[@]} -gt 0 ]] || {
  printf 'No configured agents were returned; refusing an incomplete backup.\n' >&2
  exit 1
}

path_is_absent() {
  python3 - "$1" <<'PY'
import errno
import os
import sys

try:
    os.lstat(sys.argv[1])
except OSError as error:
    if error.errno == errno.ENOENT:
        raise SystemExit(0)
    raise SystemExit(2)
raise SystemExit(1)
PY
}

for encoded_agent in "${agent_records[@]}"; do
  agent_record="$(printf '%s' "$encoded_agent" | base64 --decode)"
  agent_id="$(jq -er '.id' <<<"$agent_record")"
  agent_dir="$(jq -er '.agentDir' <<<"$agent_record")"
  agent_database="${agent_dir%/}/openclaw-agent.sqlite"
  if path_is_absent "$agent_database" &&
    path_is_absent "${agent_database}-wal" &&
    path_is_absent "${agent_database}-shm"; then
    skipped_uninitialized_agents="$(
      jq -c --arg agentId "$agent_id" \
        '. + [{agentId:$agentId,reason:"database-not-found"}]' \
        <<<"$skipped_uninitialized_agents"
    )"
    jq -nc --arg agentId "$agent_id" \
      '{event:"backup_agent_skipped",agentId:$agentId,
        reason:"database-not-found"}'
    continue
  fi
  create_sqlite_snapshot agent "$agent_id"
done

(
  cd "$stage"
  find native sqlite -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
  jq -nc \
    --arg createdAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg openclawVersion "$(openclaw --version | head -n 1)" \
    --arg nativeArchive "native/$(basename "$native_archive")" \
    --argjson nativeSkippedVolatileCount "$native_skipped_volatile_count" \
    --argjson configuredAgents "$(jq -c '[.[].id] | sort' <<<"$agents_json")" \
    --argjson sqliteSnapshots "$snapshot_index" \
    --argjson skippedUninitializedAgents "$skipped_uninitialized_agents" \
    '{schemaVersion:4,createdAt:$createdAt,openclawVersion:$openclawVersion,
      nativeArchive:$nativeArchive,nativeArchiveSkippedVolatileCount:$nativeSkippedVolatileCount,
      recoveryGuarantee:{
        canonicalState:"native archive plus verified SQLite online-backup snapshots",
        excludedVolatileArtifacts:"requires a stopped-Gateway filesystem, managed-disk, or VM snapshot"
      },configuredAgents:$configuredAgents,sqliteSnapshots:$sqliteSnapshots,
      skippedUninitializedAgents:$skippedUninitializedAgents}' > manifest.json
  sha256sum manifest.json SHA256SUMS > BUNDLE-SHA256SUMS
)

bundle="$runtime_root/openclaw-${stamp}.tar.gz"
tar --create --gzip --file "$bundle" --directory "$stage" \
  manifest.json BUNDLE-SHA256SUMS SHA256SUMS native sqlite
bundle_sha="$(sha256sum "$bundle" | cut -d' ' -f1)"
printf '%s  %s\n' "$bundle_sha" "$(basename "$bundle")" > "${bundle}.sha256"
(cd "$runtime_root" && sha256sum --check "$(basename "${bundle}.sha256")")

az login --identity --allow-no-subscriptions --output none
upload_blob() {
  local name="$1"
  az storage blob upload \
    --account-name "$OPENCLAW_BACKUP_ACCOUNT" \
    --container-name "$OPENCLAW_BACKUP_CONTAINER" \
    --name "$name" --file "$bundle" --auth-mode login \
    --overwrite false --no-progress --only-show-errors --output none
}
upload_blob "daily/$(date -u +%Y/%m/%d)/$(basename "$bundle")"

monthly_name="monthly/$(date -u +%Y/%m)/openclaw-$(date -u +%Y-%m).tar.gz"
monthly_exists="$(az storage blob exists \
  --account-name "$OPENCLAW_BACKUP_ACCOUNT" \
  --container-name "$OPENCLAW_BACKUP_CONTAINER" \
  --name "$monthly_name" --auth-mode login --only-show-errors \
  --query exists --output tsv)"
monthly_exists="${monthly_exists,,}"
if [[ "$monthly_exists" == false ]]; then
  upload_blob "$monthly_name"
elif [[ "$monthly_exists" != true ]]; then
  printf 'Could not determine whether the monthly backup exists.\n' >&2
  exit 1
fi

write_status succeeded "$bundle_sha" "$skipped_uninitialized_agents"
logger -t openclaw-backup -p local6.notice \
  '{"event":"backup","result":"succeeded","detail":"verified and uploaded"}'
