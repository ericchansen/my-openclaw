#!/usr/bin/env bash
# Bounded disk housekeeping for regenerable caches before verified backups.
set -Eeuo pipefail

umask 077
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1
[[ $# -le 1 ]] || { echo "usage: $0 [--dry-run]" >&2; exit 64; }
runtime_user="${OPENCLAW_RUNTIME_USER:-azureuser}"
runtime_home="${OPENCLAW_RUNTIME_HOME:-/home/$runtime_user}"
[[ "$runtime_user" =~ ^[a-z_][a-z0-9_-]*$ && "$runtime_home" == /* && "$runtime_home" != *$'\n'* ]] || exit 64
runtime_cache="${runtime_home}/.cache/openclaw"

if (( EUID == 0 )); then
  lock_path=/run/openclaw-housekeeping/lock
else
  lock_path="/tmp/openclaw-housekeeping-${UID}.lock"
fi
exec 9>"$lock_path"
flock -n 9 || { echo '{"event":"housekeeping_skipped","reason":"already_running"}'; exit 0; }

root_used_percent() { df --output=pcent / | tail -1 | tr -d ' %'; }
root_available_bytes() { df -B1 --output=avail / | tail -1 | tr -d ' '; }
size_bytes() { du -sb "$1" 2>/dev/null | awk '{print $1+0}'; }

before_used="$(root_used_percent)"
before_available="$(root_available_bytes)"
reclaimed_estimate=0

remove_tree() {
  local path="$1" allowed=0 bytes=0
  case "$path" in
    "$runtime_cache"/openclaw-sqlite-readonly-*) allowed=1 ;;
    /tmp/email-wrap-gocache|/tmp/email-wrap-gomodcache|/tmp/node-compile-cache) allowed=1 ;;
  esac
  (( allowed == 1 )) || { printf 'refusing path outside allowlist: %s\n' "$path" >&2; return 1; }
  [[ -e "$path" && ! -L "$path" ]] || return 0
  bytes="$(size_bytes "$path")"
  if (( DRY_RUN )); then
    printf 'would remove %s (%s bytes)\n' "$path" "$bytes"
  else
    rm -rf --one-file-system -- "$path"
  fi
  reclaimed_estimate=$((reclaimed_estimate + bytes))
}

# These SQLite copies are private read-only inspection staging. Normal exits
# remove them; entries older than 48 hours are abandoned crash residue.
if [[ -d "$runtime_cache" ]]; then
  while IFS= read -r -d '' path; do remove_tree "$path"; done < <(
    find "$runtime_cache" -mindepth 1 -maxdepth 1 -type d \
      -name 'openclaw-sqlite-readonly-*' -mmin +2880 -print0
  )
fi

# Bounded test/compiler caches are regenerable. Only remove abandoned roots.
for path in /tmp/email-wrap-gocache /tmp/email-wrap-gomodcache /tmp/node-compile-cache; do
  if [[ -d "$path" ]] && find "$path" -maxdepth 0 -mmin +1440 -print -quit | grep -q .; then
    remove_tree "$path"
  fi
done

if (( DRY_RUN )); then
  docker_reclaimable="$(docker system df --format '{{json .}}' 2>/dev/null || true)"
  printf 'would prune Docker builder cache unused for 168 hours\n'
  printf 'would vacuum archived journals to 300M\n'
else
  /usr/bin/docker builder prune --all --force --filter until=168h >/dev/null
  /usr/bin/journalctl --vacuum-size=300M >/dev/null
fi

mid_used="$(root_used_percent)"
# npm and apt caches are regenerable, but avoid needless cold-cache churn while
# the root filesystem has healthy headroom.
if (( mid_used >= 75 )); then
  if (( DRY_RUN )); then
    printf 'would clean npm and apt caches because root is %s%% used\n' "$mid_used"
  else
    runuser -u "$runtime_user" -- env HOME="$runtime_home" /usr/bin/npm cache clean --force \
      --cache "$runtime_home/.npm" >/dev/null 2>&1 || true
    /usr/bin/apt-get clean
  fi
fi

sync
after_used="$(root_used_percent)"
after_available="$(root_available_bytes)"

# Backup staging can temporarily need several GiB. Fail closed before backup if
# cleanup cannot leave 8 GiB free or root remains at warning level.
minimum_free=$((8 * 1024 * 1024 * 1024))
status="ok"
if (( after_available < minimum_free || after_used >= 85 )); then status="insufficient_headroom"; fi

json="$(jq -nc \
  --arg event housekeeping --arg status "$status" \
  --argjson beforeUsedPercent "$before_used" --argjson afterUsedPercent "$after_used" \
  --argjson beforeAvailableBytes "$before_available" --argjson afterAvailableBytes "$after_available" \
  --argjson reclaimedEstimateBytes "$reclaimed_estimate" --argjson dryRun "$DRY_RUN" \
  '{event:$event,status:$status,beforeUsedPercent:$beforeUsedPercent,
    afterUsedPercent:$afterUsedPercent,beforeAvailableBytes:$beforeAvailableBytes,
    afterAvailableBytes:$afterAvailableBytes,reclaimedEstimateBytes:$reclaimedEstimateBytes,
    dryRun:($dryRun == 1)}')"
printf '%s\n' "$json"
logger -t openclaw-housekeeping -p local6.notice -- "$json"
[[ "$status" == ok ]]
