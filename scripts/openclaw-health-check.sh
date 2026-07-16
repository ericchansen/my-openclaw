#!/usr/bin/env bash
set -Eeuo pipefail

gateway_url="${OPENCLAW_HEALTH_URL:-http://127.0.0.1:18789/health}"
backup_status="${OPENCLAW_BACKUP_STATUS:-/var/lib/openclaw-runtime/backup-status.json}"
backup_max_age_seconds="${OPENCLAW_BACKUP_MAX_AGE_SECONDS:-129600}"
runtime_root="${RUNTIME_DIRECTORY:-${HOME}/.cache/openclaw-health}"
capture_max_bytes=2097152
umask 077
mkdir -p "$runtime_root"
chmod 0700 "$runtime_root"
work="$(mktemp -d -p "$runtime_root" check-XXXXXXXX)"
trap 'rm -rf -- "$work"' EXIT
now="$(date +%s)"

CAPTURE_EXIT=1
CAPTURE_VALID=false
capture_json() {
  local name="$1" seconds="$2"
  shift 2
  local output="$work/${name}.json"
  local -a pipeline_status
  set +e
  timeout --signal=TERM --kill-after=5s "${seconds}s" "$@" 2>/dev/null |
    head -c "$capture_max_bytes" >"$output"
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  CAPTURE_EXIT="${pipeline_status[0]}"
  if (( pipeline_status[1] != 0 || $(stat -c %s -- "$output") >= capture_max_bytes )); then
    CAPTURE_EXIT=1
  fi
  CAPTURE_VALID=false
  if [[ -s "$output" ]] && jq -e 'type == "object"' "$output" >/dev/null 2>&1; then
    CAPTURE_VALID=true
  fi
}

gateway_ok=false
status_ok=false
doctor_ok=false
channel_ok=false
security_ok=false
secrets_ok=false
cron_ok=false
task_ok=false
backup_ok=false
gateway_service_ok=false

channel_probe_failures=0
security_critical=0
security_warnings=0
secrets_findings=0
cron_jobs=0
cron_failures=0
task_errors=0
task_warnings=0
backup_age_seconds=-1

if curl --silent --show-error --fail --max-time 5 --output /dev/null "$gateway_url"; then
  gateway_ok=true
fi

capture_json status 20 openclaw status --json
if [[ "$CAPTURE_VALID" == true && $CAPTURE_EXIT -eq 0 ]]; then
  status_ok=true
fi

capture_json doctor 40 openclaw doctor --lint --json
if [[ "$CAPTURE_VALID" == true && $CAPTURE_EXIT -eq 0 ]]; then
  doctor_ok=true
fi

capture_json channels 30 openclaw channels status --probe --timeout 15000 --json
if [[ "$CAPTURE_VALID" == true ]]; then
  channel_probe_failures="$(jq -r '
    [.channelAccounts // {} | to_entries[]?.value[]? |
      select(.probe? != null and .probe.ok != true)] | length
  ' "$work/channels.json" 2>/dev/null || printf 0)"
  channel_gateway_reachable="$(jq -r '(.gatewayReachable // true) != false' \
    "$work/channels.json" 2>/dev/null || printf false)"
  if [[ $CAPTURE_EXIT -eq 0 && "$channel_gateway_reachable" == true &&
    "$channel_probe_failures" -eq 0 ]]; then
    channel_ok=true
  fi
fi

capture_json security 45 openclaw security audit --json
if [[ "$CAPTURE_VALID" == true ]]; then
  security_critical="$(jq -r '.summary.critical // 0' "$work/security.json" 2>/dev/null || printf 0)"
  security_warnings="$(jq -r '.summary.warn // 0' "$work/security.json" 2>/dev/null || printf 0)"
  if [[ $CAPTURE_EXIT -eq 0 && "$security_critical" -eq 0 ]]; then
    security_ok=true
  fi
fi

capture_json secrets 60 openclaw secrets audit --allow-exec --check --json
if [[ "$CAPTURE_VALID" == true ]]; then
  secrets_findings="$(jq -r '[
    .summary.plaintextCount // 0,
    .summary.unresolvedRefCount // 0,
    .summary.shadowedRefCount // 0,
    .summary.legacyResidueCount // 0
  ] | add' "$work/secrets.json" 2>/dev/null || printf 0)"
  if [[ $CAPTURE_EXIT -eq 0 && "$secrets_findings" -eq 0 ]]; then
    secrets_ok=true
  fi
fi

capture_json cron 25 openclaw cron status --json
if [[ "$CAPTURE_VALID" == true ]]; then
  cron_jobs="$(jq -r '.jobs // 0' "$work/cron.json" 2>/dev/null || printf 0)"
  cron_enabled="$(jq -r '.enabled == true' "$work/cron.json" 2>/dev/null || printf false)"
  if [[ $CAPTURE_EXIT -eq 0 && "$cron_enabled" == true ]]; then
    cron_ok=true
  fi
fi

capture_json cron_list 25 openclaw cron list --json
if [[ "$CAPTURE_VALID" == true ]]; then
  cron_failures="$(jq -r '[
    .jobs[]? | select(.enabled == true and ((.state.consecutiveErrors // 0) > 0))
  ] | length' "$work/cron_list.json" 2>/dev/null || printf 0)"
  if [[ $CAPTURE_EXIT -ne 0 || "$cron_failures" -ne 0 ]]; then
    cron_ok=false
  fi
else
  cron_ok=false
fi

capture_json tasks 25 openclaw tasks audit --json
if [[ "$CAPTURE_VALID" == true ]]; then
  task_errors="$(jq -r '.summary.combined.errors // 0' "$work/tasks.json" 2>/dev/null || printf 0)"
  task_warnings="$(jq -r '.summary.combined.warnings // 0' "$work/tasks.json" 2>/dev/null || printf 0)"
  if [[ $CAPTURE_EXIT -eq 0 && "$task_errors" -eq 0 ]]; then
    task_ok=true
  fi
fi

if [[ -f "$backup_status" ]]; then
  backup_epoch="$(date -d "$(jq -r '.timestamp // empty' "$backup_status" 2>/dev/null)" +%s 2>/dev/null || printf 0)"
  backup_result="$(jq -r '.result // "unknown"' "$backup_status" 2>/dev/null || printf unknown)"
  if (( backup_epoch > 0 )); then
    backup_age_seconds=$((now - backup_epoch))
  fi
  if [[ "$backup_result" == succeeded ]] &&
    (( backup_age_seconds >= 0 && backup_age_seconds <= backup_max_age_seconds )); then
    backup_ok=true
  fi
fi

gateway_active_state=unknown
gateway_result=unknown
gateway_restarts=0
while IFS='=' read -r property value; do
  case "$property" in
    ActiveState) gateway_active_state="$value" ;;
    Result) gateway_result="${value:-unknown}" ;;
    NRestarts) gateway_restarts="${value:-0}" ;;
  esac
done < <(systemctl show openclaw-gateway.service \
  --property=ActiveState --property=Result --property=NRestarts --no-pager 2>/dev/null)
if [[ "$gateway_active_state" == active && "$gateway_result" == success ]]; then
  gateway_service_ok=true
fi

read -r memory_total_bytes memory_available_bytes < <(
  free -b | awk '/^Mem:/ {print $2, $7}'
)
read -r swap_total_bytes swap_free_bytes < <(
  free -b | awk '/^Swap:/ {print $2, $4}'
)
memory_total_bytes="${memory_total_bytes:-0}"
memory_available_bytes="${memory_available_bytes:-0}"
swap_total_bytes="${swap_total_bytes:-0}"
swap_free_bytes="${swap_free_bytes:-0}"
memory_used_percent=0
swap_used_bytes=$((swap_total_bytes - swap_free_bytes))
swap_used_percent=0
if (( memory_total_bytes > 0 )); then
  memory_used_percent=$(((memory_total_bytes - memory_available_bytes) * 100 / memory_total_bytes))
fi
if (( swap_total_bytes > 0 )); then
  swap_used_percent=$((swap_used_bytes * 100 / swap_total_bytes))
fi

disk_percent="$(df --output=pcent / | tail -n 1 | tr -cd '0-9')"
disk_level=normal
exit_code=0
if (( disk_percent >= 92 )); then
  disk_level=critical
  exit_code=2
elif (( disk_percent >= 85 )); then
  disk_level=high
  exit_code=1
elif (( disk_percent >= 75 )); then
  disk_level=warning
fi
for result in \
  "$gateway_ok" "$gateway_service_ok" "$status_ok" "$doctor_ok" "$channel_ok" \
  "$security_ok" "$secrets_ok" "$cron_ok" "$task_ok" "$backup_ok"; do
  if [[ "$result" != true && $exit_code -eq 0 ]]; then
    exit_code=1
  fi
done

payload="$(jq -nc \
  --arg event health \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson gatewayOk "$gateway_ok" \
  --argjson gatewayServiceOk "$gateway_service_ok" \
  --arg gatewayActiveState "$gateway_active_state" \
  --arg gatewayResult "$gateway_result" \
  --argjson gatewayRestarts "$gateway_restarts" \
  --argjson statusOk "$status_ok" \
  --argjson doctorOk "$doctor_ok" \
  --argjson channelOk "$channel_ok" \
  --argjson channelProbeFailures "$channel_probe_failures" \
  --argjson securityOk "$security_ok" \
  --argjson securityCritical "$security_critical" \
  --argjson securityWarnings "$security_warnings" \
  --argjson secretsOk "$secrets_ok" \
  --argjson secretsFindings "$secrets_findings" \
  --argjson cronOk "$cron_ok" \
  --argjson cronJobs "$cron_jobs" \
  --argjson cronFailures "$cron_failures" \
  --argjson taskOk "$task_ok" \
  --argjson taskErrors "$task_errors" \
  --argjson taskWarnings "$task_warnings" \
  --argjson backupOk "$backup_ok" \
  --argjson backupAgeSeconds "$backup_age_seconds" \
  --argjson memoryUsedPercent "$memory_used_percent" \
  --argjson memoryAvailableBytes "$memory_available_bytes" \
  --argjson swapUsedPercent "$swap_used_percent" \
  --argjson swapUsedBytes "$swap_used_bytes" \
  --argjson diskPercent "$disk_percent" \
  --arg diskLevel "$disk_level" \
  '{
    event:$event,timestamp:$timestamp,
    gatewayOk:$gatewayOk,gatewayServiceOk:$gatewayServiceOk,
    gatewayActiveState:$gatewayActiveState,gatewayResult:$gatewayResult,
    gatewayRestarts:$gatewayRestarts,statusOk:$statusOk,doctorOk:$doctorOk,
    channelOk:$channelOk,channelProbeFailures:$channelProbeFailures,
    securityOk:$securityOk,securityCritical:$securityCritical,securityWarnings:$securityWarnings,
    secretsOk:$secretsOk,secretsFindings:$secretsFindings,
    cronOk:$cronOk,cronJobs:$cronJobs,cronFailures:$cronFailures,
    taskOk:$taskOk,taskErrors:$taskErrors,taskWarnings:$taskWarnings,
    backupOk:$backupOk,backupAgeSeconds:$backupAgeSeconds,
    memoryUsedPercent:$memoryUsedPercent,memoryAvailableBytes:$memoryAvailableBytes,
    swapUsedPercent:$swapUsedPercent,swapUsedBytes:$swapUsedBytes,
    diskPercent:$diskPercent,diskLevel:$diskLevel
  }')"
printf '%s\n' "$payload"
if (( exit_code == 0 )); then
  logger -t openclaw-health -p local6.notice -- "$payload"
else
  logger -t openclaw-health -p local6.warning -- "$payload"
fi
exit "$exit_code"
