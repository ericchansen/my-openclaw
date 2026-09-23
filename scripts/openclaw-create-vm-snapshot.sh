#!/usr/bin/env bash
set -Eeuo pipefail

umask 077
resource_group="${OPENCLAW_AZURE_RESOURCE_GROUP:-}"
vm_name="${OPENCLAW_AZURE_VM_NAME:-openclaw-vm}"
readonly name_prefix='openclaw-auto-daily-'
readonly retention=7
[[ -n "$resource_group" ]] || {
  printf 'OPENCLAW_AZURE_RESOURCE_GROUP is required.\n' >&2
  exit 64
}

for command in az jq flock mktemp install base64; do
  command -v "$command" >/dev/null
 done

state_root="${STATE_DIRECTORY:-/var/lib/openclaw-vm-snapshot}"
mkdir -p "$state_root"
chmod 0700 "$state_root"
exec 9>"$state_root/snapshot.lock"
flock -n 9 || {
  jq -nc '{event:"vm_snapshot",result:"skipped",reason:"already_running"}'
  exit 0
}

tmpdir="$(mktemp -d -p "$state_root" snapshot.XXXXXXXX)"
cleanup() { rm -rf -- "$tmpdir"; }
trap cleanup EXIT

az login --identity --allow-no-subscriptions --output none
if [[ -n "${OPENCLAW_AZURE_SUBSCRIPTION_ID:-}" ]]; then
  az account set --subscription "$OPENCLAW_AZURE_SUBSCRIPTION_ID"
fi
os_disk_id="$(az vm show --resource-group "$resource_group" --name "$vm_name" --query 'storageProfile.osDisk.managedDisk.id' -o tsv)"
[[ "$os_disk_id" =~ ^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Compute/disks/[^/]+$ ]] || {
  printf 'Unexpected OS disk resource ID.\n' >&2
  exit 1
}
disk_location="$(az disk show --ids "$os_disk_id" --query location -o tsv)"
[[ -n "$disk_location" ]] || { printf 'OS disk location is empty.\n' >&2; exit 1; }

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
snapshot_name="${name_prefix}${stamp}"
[[ "$snapshot_name" =~ ^openclaw-auto-daily-[0-9]{8}T[0-9]{6}Z$ ]] || exit 1
az snapshot create \
  --resource-group "$resource_group" \
  --name "$snapshot_name" \
  --source "$os_disk_id" \
  --location "$disk_location" \
  --incremental true \
  --tags purpose=openclaw-automated-backup retention=7 createdBy=openclaw-vm-snapshot \
  --only-show-errors -o json > "$tmpdir/create.json"
az snapshot show --resource-group "$resource_group" --name "$snapshot_name" -o json > "$tmpdir/readback.json"

jq -e --arg name "$snapshot_name" --arg source "${os_disk_id,,}" '
  .name == $name and
  .provisioningState == "Succeeded" and
  .incremental == true and
  ((.creationData.sourceResourceId | ascii_downcase) == $source) and
  .tags.purpose == "openclaw-automated-backup" and
  .tags.retention == "7" and
  .tags.createdBy == "openclaw-vm-snapshot"
' "$tmpdir/readback.json" >/dev/null || {
  jq -nc --arg name "$snapshot_name" '{event:"vm_snapshot",result:"failed",reason:"readback_mismatch",name:$name}' >&2
  exit 1
}
install -m 0600 "$tmpdir/readback.json" "$state_root/last-created.json"

az snapshot list --resource-group "$resource_group" -o json > "$tmpdir/all.json"
jq -S --arg prefix "$name_prefix" '
  [.[] | select(.name | test("^openclaw-auto-daily-[0-9]{8}T[0-9]{6}Z$")) |
    {name,id,timeCreated,provisioningState,incremental,sourceResourceId:.creationData.sourceResourceId,tags}] |
  sort_by(.timeCreated,.name) | reverse
' "$tmpdir/all.json" > "$tmpdir/automated.json"
jq -e --arg name "$snapshot_name" --arg source "${os_disk_id,,}" '
  length >= 1 and any(.[]; .name == $name and .provisioningState == "Succeeded" and
    .incremental == true and ((.sourceResourceId|ascii_downcase) == $source) and
    .tags.purpose == "openclaw-automated-backup" and .tags.retention == "7" and
    .tags.createdBy == "openclaw-vm-snapshot")
' "$tmpdir/automated.json" >/dev/null || exit 1

# Creation and readback succeeded; only now retire older snapshots with the exact automated prefix.
while IFS= read -r encoded; do
  old_name="$(printf '%s' "$encoded" | base64 --decode)"
  [[ "$old_name" =~ ^openclaw-auto-daily-[0-9]{8}T[0-9]{6}Z$ ]] || exit 1
  jq -nc --arg name "$old_name" '{event:"vm_snapshot",phase:"retire",name:$name}'
  az snapshot delete --resource-group "$resource_group" --name "$old_name" --only-show-errors
 done < <(jq -r --argjson keep "$retention" '.[$keep:][]?.name | @base64' "$tmpdir/automated.json")

az snapshot list --resource-group "$resource_group" -o json > "$tmpdir/after.json"
jq -S '[.[] | select(.name | test("^openclaw-auto-daily-[0-9]{8}T[0-9]{6}Z$")) |
  {name,id,timeCreated,provisioningState,incremental,sourceResourceId:.creationData.sourceResourceId,tags}] |
  sort_by(.timeCreated,.name) | reverse' "$tmpdir/after.json" > "$tmpdir/automated-after.json"
jq -e --arg name "$snapshot_name" --argjson retention "$retention" '
  length <= $retention and any(.[]; .name == $name and .provisioningState == "Succeeded")
' "$tmpdir/automated-after.json" >/dev/null || exit 1
install -m 0600 "$tmpdir/automated-after.json" "$state_root/last-automated-inventory.json"
jq -nc --arg name "$snapshot_name" --arg source "$os_disk_id" \
  --argjson retained "$(jq 'length' "$tmpdir/automated-after.json")" \
  '{event:"vm_snapshot",result:"succeeded",name:$name,sourceResourceId:$source,incremental:true,retained:$retained,consistency:"crash-consistent"}'
