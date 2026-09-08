#!/usr/bin/env bash
set -Eeuo pipefail

: "${OPENCLAW_BACKUP_ACCOUNT:?OPENCLAW_BACKUP_ACCOUNT is required}"
: "${OPENCLAW_BACKUP_CONTAINER:?OPENCLAW_BACKUP_CONTAINER is required}"
[[ $# -eq 1 && "$1" != -* ]] || {
  printf 'Usage: %s <blob-name>\n' "$0" >&2
  exit 64
}

blob_name="$1"
for command in az jq openclaw python3 sha256sum; do
  command -v "$command" >/dev/null
done
umask 077
runtime_root="${RUNTIME_DIRECTORY:-${HOME}/.cache/openclaw-restore-verify}"
mkdir -p "$runtime_root"
chmod 0700 "$runtime_root"
stage="$(mktemp -d -p "$runtime_root" verify-XXXXXXXX)"
phase=download
cleanup() {
  local code=$?
  if (( code != 0 )); then
    printf 'Restore verification failed during %s; production state was not modified.\n' "$phase" >&2
  fi
  rm -rf -- "$stage"
}
trap cleanup EXIT
bundle="$stage/bundle.tar.gz"
extract_root="$stage/extracted"
mkdir -m 0700 "$extract_root"

az login --identity --allow-no-subscriptions --output none
az storage blob download \
  --account-name "$OPENCLAW_BACKUP_ACCOUNT" \
  --container-name "$OPENCLAW_BACKUP_CONTAINER" \
  --name "$blob_name" --file "$bundle" --auth-mode login \
  --overwrite true --no-progress --only-show-errors --output none

phase=extract
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

phase=manifest
(
  cd "$extract_root"
  [[ "$(wc -l < BUNDLE-SHA256SUMS)" -eq 2 ]]
  awk '
    $2 == "manifest.json" { manifest += 1; next }
    $2 == "SHA256SUMS" { sums += 1; next }
    { invalid = 1 }
    END { exit !(manifest == 1 && sums == 1 && !invalid) }
  ' BUNDLE-SHA256SUMS
  awk '
    $2 ~ /^native\/[A-Za-z0-9._:+-]+\.tar\.gz$/ { native += 1; next }
    $2 ~ /^sqlite\/[A-Za-z0-9._+-]+\/[A-Za-z0-9._+-]+$/ { sqlite += 1; next }
    { invalid = 1 }
    END { exit !(native == 1 && sqlite >= 2 && !invalid) }
  ' SHA256SUMS
  sha256sum --check BUNDLE-SHA256SUMS
  sha256sum --check SHA256SUMS
  jq -e '
    type == "object" and .schemaVersion == 4 and
    (.nativeArchive | type == "string" and
      test("^native/[A-Za-z0-9._:+-]+\\.tar\\.gz$")) and
    (.nativeArchiveSkippedVolatileCount |
      type == "number" and . >= 0 and floor == .) and
    .recoveryGuarantee.canonicalState ==
      "native archive plus verified SQLite online-backup snapshots" and
    .recoveryGuarantee.excludedVolatileArtifacts ==
      "requires a stopped-Gateway filesystem, managed-disk, or VM snapshot" and
    ([.sqliteSnapshots[] | select(.role == "global")] | length) == 1 and
    (.configuredAgents | type == "array" and length >= 1 and
      all(.[]; type == "string" and
        test("^[A-Za-z0-9_][A-Za-z0-9_-]{0,63}$")) and
      (unique | length) == length) and
    (.skippedUninitializedAgents | type == "array" and
      all(.[];
        type == "object" and
        (.agentId | type == "string" and
          test("^[A-Za-z0-9_][A-Za-z0-9_-]{0,63}$")) and
        .reason == "database-not-found" and
        (keys | sort) == ["agentId", "reason"])) and
    all(.sqliteSnapshots[];
      type == "object" and
      (.role == "global" or .role == "agent") and
      (.path | type == "string" and
        test("^sqlite/[A-Za-z0-9][A-Za-z0-9._-]{0,254}$")) and
      (if .role == "agent"
        then (.agentId | type == "string" and
          test("^[A-Za-z0-9_][A-Za-z0-9_-]{0,63}$"))
        else has("agentId") | not
      end)
    ) and
    (([.sqliteSnapshots[] | select(.role == "agent") | .agentId] +
      [.skippedUninitializedAgents[].agentId]) as $covered |
      ($covered | unique | length) == ($covered | length) and
      ($covered | sort) == (.configuredAgents | sort))
  ' manifest.json >/dev/null
  expected_checksum_count="$(
    jq -er '1 + (2 * (.sqliteSnapshots | length))' manifest.json
  )"
  [[ "$(wc -l < SHA256SUMS)" -eq "$expected_checksum_count" ]]
)

native_relative="$(jq -er '.nativeArchive' "$extract_root/manifest.json")"
native_archive="$(realpath -e "$extract_root/$native_relative")"
[[ "$native_archive" == "$extract_root/native/"* ]] || exit 1
phase=native_verify
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
  printf 'Native archive verification returned an unsupported result.\n' >&2
  exit 1
fi
restore_target="$stage/restored-native"
phase=native_restore
native_restore_json="$(openclaw backup restore "$native_archive" \
  --target "$restore_target" --json)"
if ! jq -e --arg archive "$native_archive" --arg target "$restore_target" '
  type == "object" and .ok == true and
  .archivePath == $archive and .targetPath == $target and
  (.archiveRoot | type == "string" and length > 0) and
  (.warnings | type == "array" and length > 0 and all(.[]; type == "string"))
' >/dev/null <<<"$native_restore_json"; then
  printf 'Native archive restore returned an unsupported result.\n' >&2
  exit 1
fi
[[ -d "$restore_target" ]]

phase=sqlite_verify
# Tabs collapse empty fields in Bash read; the global snapshot has no agent ID.
while IFS='|' read -r role agent_id relative; do
  snapshot="$(realpath -e "$extract_root/$relative")"
  [[ "$snapshot" == "$extract_root/sqlite/"* ]] || exit 1
  sqlite_verify_json="$(openclaw backup sqlite verify "$snapshot" \
    --scratch "$stage" --json)"
  if ! jq -e --arg path "$snapshot" --arg role "$role" --arg agent "$agent_id" '
    type == "object" and .ok == true and .snapshotPath == $path and
    .manifest.schemaVersion == 1 and .manifest.database.role == $role and
    (if $role == "agent" then .manifest.database.agentId == $agent else true end) and
    .manifest.artifact.path == "database.sqlite" and
    (.manifest.artifact.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.manifest.artifact.sizeBytes | type == "number" and . > 0 and floor == .)
  ' >/dev/null <<<"$sqlite_verify_json"; then
    printf 'SQLite snapshot verification returned an unsupported result for %s.\n' "$role" >&2
    exit 1
  fi
done < <(jq -er '.sqliteSnapshots[] | [.role, (.agentId // ""), .path] | join("|")' \
  "$extract_root/manifest.json")

printf '{"event":"restore_verification","result":"succeeded","productionModified":false}\n'
