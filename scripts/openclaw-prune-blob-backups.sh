#!/usr/bin/env bash
set -Eeuo pipefail

umask 077
readonly keep_daily="${OPENCLAW_BACKUP_KEEP_DAILY:-7}"
readonly keep_monthly="${OPENCLAW_BACKUP_KEEP_MONTHLY:-2}"
[[ "$keep_daily" =~ ^[1-9][0-9]*$ && "$keep_monthly" =~ ^[1-9][0-9]*$ ]] || {
  printf 'Backup retention values must be positive integers.\n' >&2
  exit 64
}

dry_run=false
case "${1:-}" in
  '') ;;
  --dry-run) dry_run=true ;;
  *) printf 'Usage: %s [--dry-run]\n' "$0" >&2; exit 64 ;;
esac

: "${OPENCLAW_BACKUP_ACCOUNT:?OPENCLAW_BACKUP_ACCOUNT is required}"
: "${OPENCLAW_BACKUP_CONTAINER:?OPENCLAW_BACKUP_CONTAINER is required}"
for command in az jq flock mktemp install base64 cmp; do
  command -v "$command" >/dev/null
 done

state_parent="${STATE_DIRECTORY:-/var/lib/openclaw-runtime}"
state_root="$state_parent/blob-retention"
mkdir -p "$state_root"
chmod 0700 "$state_root"
exec 9>"$state_root/prune.lock"
flock -n 9 || {
  jq -nc '{event:"blob_retention",result:"skipped",reason:"already_running"}'
  exit 0
}

tmpdir="$(mktemp -d -p "$state_root" blob-prune.XXXXXXXX)"
cleanup() { rm -rf -- "$tmpdir"; }
trap cleanup EXIT

az login --identity --allow-no-subscriptions --output none
if [[ -n "${OPENCLAW_AZURE_SUBSCRIPTION_ID:-}" ]]; then az account set --subscription "$OPENCLAW_AZURE_SUBSCRIPTION_ID"; fi
az storage blob list \
  --account-name "$OPENCLAW_BACKUP_ACCOUNT" \
  --container-name "$OPENCLAW_BACKUP_CONTAINER" \
  --auth-mode login --include m --only-show-errors -o json > "$tmpdir/inventory.json"

jq -e '
  type == "array" and
  all(.[]; ((.name | type) == "string") and (.name | length > 0) and
           (.name | explode | all(. >= 32 and . != 127)) and
           ((.properties.lastModified | type) == "string") and (.properties.lastModified | length > 0) and
           ((.properties.contentLength | type) == "number") and (.properties.contentLength >= 0)) and
  ([.[].name] | unique | length) == length
' "$tmpdir/inventory.json" >/dev/null

jq -S --argjson keepDaily "$keep_daily" --argjson keepMonthly "$keep_monthly" '
  def daily: "^daily/[0-9]{4}/[0-9]{2}/[0-9]{2}/openclaw-[0-9]{8}T[0-9]{6}Z[.]tar[.]gz$";
  def monthly: "^monthly/[0-9]{4}/[0-9]{2}/openclaw-[0-9]{4}-[0-9]{2}[.]tar[.]gz$";
  def managed: (.name | test(daily) or test(monthly));
  def ranked($prefix):
    [ .[] | select(managed and (.name | startswith($prefix))) ] |
    sort_by(.properties.lastModified, .name) | reverse;
  (ranked("daily/")) as $daily |
  (ranked("monthly/")) as $monthly |
  (($daily[0:$keepDaily] + $monthly[0:$keepMonthly]) | map(.name) | sort) as $keep |
  {keep:$keep,
   delete:(([.[] | select(managed) | .name] - $keep) | sort),
   before:{count:length,bytes:([.[].properties.contentLength] | add // 0),
           daily:($daily|length),monthly:($monthly|length),
           managed:([.[] | select(managed)]|length),
           other:([.[] | select(managed|not)]|length)}}
' "$tmpdir/inventory.json" > "$tmpdir/plan.json"

jq -e '
  (.keep | type == "array") and (.delete | type == "array") and
  ((.keep + .delete) | unique | length) == ((.keep|length) + (.delete|length))
' "$tmpdir/plan.json" >/dev/null
install -m 0600 "$tmpdir/inventory.json" "$state_root/blob-prune-last-inventory.json"
install -m 0600 "$tmpdir/plan.json" "$state_root/blob-prune-last-plan.json"

jq -nc --argjson summary "$(jq -c '{before,keepCount:(.keep|length),deleteCount:(.delete|length)}' "$tmpdir/plan.json")" \
  --argjson dryRun "$dry_run" '{event:"blob_retention",phase:"plan",dryRun:$dryRun} + $summary'
while IFS= read -r encoded; do
  name="$(printf '%s' "$encoded" | base64 --decode)"
  jq -nc --arg name "$name" --argjson dryRun "$dry_run" \
    '{event:"blob_retention",phase:"delete",dryRun:$dryRun,name:$name}'
  if [[ "$dry_run" == false ]]; then
    az storage blob delete \
      --account-name "$OPENCLAW_BACKUP_ACCOUNT" \
      --container-name "$OPENCLAW_BACKUP_CONTAINER" \
      --name "$name" --delete-snapshots include \
      --auth-mode login --only-show-errors --output none
  fi
done < <(jq -r '.delete[] | @base64' "$tmpdir/plan.json")

if [[ "$dry_run" == true ]]; then
  jq -nc --argjson keepCount "$(jq '.keep|length' "$tmpdir/plan.json")" \
    --argjson deleteCount "$(jq '.delete|length' "$tmpdir/plan.json")" \
    '{event:"blob_retention",result:"dry_run_succeeded",keepCount:$keepCount,deleteCount:$deleteCount}'
  exit 0
fi

az storage blob list \
  --account-name "$OPENCLAW_BACKUP_ACCOUNT" \
  --container-name "$OPENCLAW_BACKUP_CONTAINER" \
  --auth-mode login --include m --only-show-errors -o json > "$tmpdir/after.json"
jq -S '[.[].name] | sort' "$tmpdir/after.json" > "$tmpdir/after-names.json"
jq -S '.keep' "$tmpdir/plan.json" > "$tmpdir/keep-names.json"
 jq -S '[.[] | select((.name | test("^daily/[0-9]{4}/[0-9]{2}/[0-9]{2}/openclaw-[0-9]{8}T[0-9]{6}Z[.]tar[.]gz$")) or
  (.name | test("^monthly/[0-9]{4}/[0-9]{2}/openclaw-[0-9]{4}-[0-9]{2}[.]tar[.]gz$")) | not)] | map(.name) | sort' \
  "$tmpdir/inventory.json" > "$tmpdir/unmanaged-names.json"
jq -S -s '.[0] + .[1]' "$tmpdir/keep-names.json" "$tmpdir/unmanaged-names.json" > "$tmpdir/expected-names.json"
cmp -s "$tmpdir/after-names.json" "$tmpdir/expected-names.json" || {
  jq -nc --argjson expected "$(cat "$tmpdir/expected-names.json")" --argjson actual "$(cat "$tmpdir/after-names.json")" \
    '{event:"blob_retention",result:"failed",reason:"post_delete_name_mismatch",expected:$expected,actual:$actual}' >&2
  exit 1
}
install -m 0600 "$tmpdir/after.json" "$state_root/blob-prune-last-after.json"
jq -nc \
  --argjson count "$(jq 'length' "$tmpdir/after.json")" \
  --argjson bytes "$(jq '[.[].properties.contentLength] | add // 0' "$tmpdir/after.json")" \
  '{event:"blob_retention",result:"succeeded",count:$count,bytes:$bytes}'
