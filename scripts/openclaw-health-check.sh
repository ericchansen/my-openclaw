#!/usr/bin/env bash
set -Eeuo pipefail

gateway_url="${OPENCLAW_HEALTH_URL:-http://127.0.0.1:18789/health}"
backup_status="${OPENCLAW_BACKUP_STATUS:-/var/lib/openclaw-runtime/backup-status.json}"
backup_max_age_seconds="${OPENCLAW_BACKUP_MAX_AGE_SECONDS:-129600}"
health_state_dir="${OPENCLAW_HEALTH_STATE_DIR:-/var/lib/openclaw-runtime/health}"
runtime_root="${RUNTIME_DIRECTORY:-$health_state_dir}"
cron_recent_failure_seconds="${OPENCLAW_CRON_RECENT_FAILURE_SECONDS:-7200}"
cron_failure_threshold="${OPENCLAW_CRON_FAILURE_THRESHOLD:-2}"
capture_max_bytes=2097152
umask 077

[[ "$cron_recent_failure_seconds" =~ ^[0-9]+$ ]] || exit 64
[[ "$cron_failure_threshold" =~ ^[1-9][0-9]*$ ]] || exit 64
mkdir -p "$health_state_dir" "$runtime_root"
chmod 0700 "$health_state_dir" "$runtime_root"
exec 9>"$health_state_dir/check.lock"
if ! flock --nonblock 9; then
  printf 'OpenClaw health check is already running.\n' >&2
  exit 75
fi

work="$(mktemp -d -p "$runtime_root" check-XXXXXXXX)"
trap 'rm -rf -- "$work"' EXIT
now="$(date +%s)"
now_ms=$((now * 1000))
check_started_ms="$(date +%s%3N)"

CAPTURE_EXIT=1
CAPTURE_VALID=false
CAPTURE_REASON=not_run
CAPTURE_DURATION_MS=0
capture_json() {
  local name="$1" seconds="$2"
  shift 2
  local output="$work/${name}.json"
  local -a pipeline_status
  local started_ms output_bytes
  started_ms="$(date +%s%3N)"
  set +e
  timeout --signal=TERM --kill-after=5s "${seconds}s" "$@" 2>/dev/null |
    head -c "$capture_max_bytes" >"$output"
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  CAPTURE_DURATION_MS=$(($(date +%s%3N) - started_ms))
  CAPTURE_EXIT="${pipeline_status[0]}"
  CAPTURE_VALID=false
  CAPTURE_REASON=none
  output_bytes="$(stat -c %s -- "$output")"
  if (( pipeline_status[1] != 0 || output_bytes >= capture_max_bytes )); then
    CAPTURE_EXIT=1
    CAPTURE_REASON=output_limit
  elif [[ ! -s "$output" ]]; then
    CAPTURE_REASON=empty_output
  else
    if jq -e 'type == "object"' "$output" >/dev/null 2>&1; then
      CAPTURE_VALID=true
    fi
    if (( CAPTURE_EXIT == 124 || CAPTURE_EXIT == 137 )); then
      CAPTURE_REASON=timeout
    elif (( CAPTURE_EXIT != 0 )); then
      CAPTURE_REASON=command_exit
    elif [[ "$CAPTURE_VALID" != true ]]; then
      CAPTURE_REASON=invalid_json
    fi
  fi
}

gateway_ok=false
status_ok=false
doctor_ok=false
channel_ok=false
security_ok=false
secrets_ok=false
cron_ok=false
cron_scheduler_ok=false
cron_scheduler_confirmed_disabled=false
cron_state_ok=false
task_ok=false
backup_ok=false
gateway_service_ok=false

gateway_probe_attempts=0
gateway_probe_duration_ms=0
gateway_failure_reason=not_run
status_failure_reason=not_run
doctor_failure_reason=not_run
channel_failure_reason=not_run
security_failure_reason=not_run
secrets_failure_reason=not_run
cron_scheduler_failure_reason=not_run
cron_state_failure_reason=not_run
task_failure_reason=not_run
backup_failure_reason=missing

status_duration_ms=0
doctor_duration_ms=0
channel_duration_ms=0
security_duration_ms=0
secrets_duration_ms=0
cron_scheduler_duration_ms=0
cron_state_duration_ms=0
task_duration_ms=0

channel_probe_failures=0
security_critical=0
security_warnings=0
secrets_findings=0
cron_jobs=0
cron_failures=0
cron_recent_failures=0
task_errors=0
task_warnings=0
backup_age_seconds=-1

gateway_probe_started_ms="$(date +%s%3N)"
for attempt in 1 2 3; do
  gateway_probe_attempts="$attempt"
  set +e
  curl --silent --show-error --fail --max-time 5 --output /dev/null \
    "$gateway_url" 2>"$work/gateway.err"
  gateway_exit=$?
  set -e
  if (( gateway_exit == 0 )); then
    gateway_ok=true
    gateway_failure_reason=none
    break
  fi
  case "$gateway_exit" in
    22) gateway_failure_reason=http ;;
    7) gateway_failure_reason=connection ;;
    28) gateway_failure_reason=timeout ;;
    *) gateway_failure_reason=curl_error ;;
  esac
  if (( attempt < 3 )); then
    sleep 2
  fi
done
gateway_probe_duration_ms=$(($(date +%s%3N) - gateway_probe_started_ms))

capture_json status 20 openclaw status --json
status_duration_ms="$CAPTURE_DURATION_MS"
status_failure_reason="$CAPTURE_REASON"
if [[ "$CAPTURE_VALID" == true && $CAPTURE_EXIT -eq 0 ]]; then
  status_ok=true
fi

capture_json doctor 40 openclaw doctor --lint --json
doctor_duration_ms="$CAPTURE_DURATION_MS"
doctor_failure_reason="$CAPTURE_REASON"
if [[ "$CAPTURE_VALID" == true && $CAPTURE_EXIT -eq 0 ]]; then
  doctor_ok=true
fi

capture_json channels 30 openclaw channels status --probe --timeout 15000 --json
channel_duration_ms="$CAPTURE_DURATION_MS"
channel_failure_reason="$CAPTURE_REASON"
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
  elif [[ "$channel_gateway_reachable" != true ]]; then
    channel_failure_reason=gateway_unreachable
  elif (( channel_probe_failures > 0 )); then
    channel_failure_reason=probe_failure
  fi
fi

capture_json security 45 openclaw security audit --json
security_duration_ms="$CAPTURE_DURATION_MS"
security_failure_reason="$CAPTURE_REASON"
if [[ "$CAPTURE_VALID" == true ]]; then
  security_critical="$(jq -r '.summary.critical // 0' "$work/security.json" 2>/dev/null || printf 0)"
  security_warnings="$(jq -r '.summary.warn // 0' "$work/security.json" 2>/dev/null || printf 0)"
  if [[ $CAPTURE_EXIT -eq 0 && "$security_critical" -eq 0 ]]; then
    security_ok=true
  elif (( security_critical > 0 )); then
    security_failure_reason=critical_findings
  fi
fi

capture_json secrets 60 openclaw secrets audit --allow-exec --check --json
secrets_duration_ms="$CAPTURE_DURATION_MS"
secrets_failure_reason="$CAPTURE_REASON"
if [[ "$CAPTURE_VALID" == true ]]; then
  secrets_findings="$(jq -r '[
    .summary.plaintextCount // 0,
    .summary.unresolvedRefCount // 0,
    .summary.shadowedRefCount // 0,
    .summary.legacyResidueCount // 0
  ] | add' "$work/secrets.json" 2>/dev/null || printf 0)"
  if [[ $CAPTURE_EXIT -eq 0 && "$secrets_findings" -eq 0 ]]; then
    secrets_ok=true
  elif (( secrets_findings > 0 )); then
    secrets_failure_reason=audit_findings
  fi
fi

capture_json cron 25 openclaw cron status --json
cron_scheduler_duration_ms="$CAPTURE_DURATION_MS"
cron_scheduler_failure_reason="$CAPTURE_REASON"
if [[ "$CAPTURE_VALID" == true ]]; then
  cron_jobs="$(jq -r '.jobs // 0' "$work/cron.json" 2>/dev/null || printf 0)"
  cron_enabled="$(jq -r '.enabled == true' "$work/cron.json" 2>/dev/null || printf false)"
  if [[ $CAPTURE_EXIT -eq 0 && "$cron_enabled" == true ]]; then
    cron_scheduler_ok=true
  elif [[ "$cron_enabled" != true ]]; then
    cron_scheduler_confirmed_disabled=true
    cron_scheduler_failure_reason=disabled
  fi
fi

capture_json cron_list 25 openclaw cron list --json
cron_state_duration_ms="$CAPTURE_DURATION_MS"
cron_state_failure_reason="$CAPTURE_REASON"
if [[ "$CAPTURE_VALID" == true && $CAPTURE_EXIT -eq 0 ]]; then
  cron_state_ok=true
  cron_failures="$(jq -r '[
    .jobs[]? | select(.enabled == true and ((.state.consecutiveErrors // 0) > 0))
  ] | length' "$work/cron_list.json" 2>/dev/null || printf 0)"
  cron_recent_failures="$(jq -r \
    --argjson nowMs "$now_ms" \
    --argjson windowMs "$((cron_recent_failure_seconds * 1000))" \
    --argjson threshold "$cron_failure_threshold" '
    [
      .jobs[]?
      | select(.enabled == true)
      | (.state.lastRunAtMs // 0) as $lastRun
      | select((.state.consecutiveErrors // 0) >= $threshold)
      | select(
          $lastRun > 0
          and $lastRun <= ($nowMs + 300000)
          and ($nowMs - $lastRun) <= $windowMs
        )
    ] | length
  ' "$work/cron_list.json" 2>/dev/null || printf 0)"
  if (( cron_recent_failures > 0 )); then
    cron_state_failure_reason=recent_repeated_errors
  fi
fi
if [[ "$cron_scheduler_ok" == true && "$cron_state_ok" == true &&
  "$cron_recent_failures" -eq 0 ]]; then
  cron_ok=true
fi

capture_json tasks 25 openclaw tasks audit --json
task_duration_ms="$CAPTURE_DURATION_MS"
task_failure_reason="$CAPTURE_REASON"
if [[ "$CAPTURE_VALID" == true ]]; then
  task_errors="$(jq -r '.summary.combined.errors // 0' "$work/tasks.json" 2>/dev/null || printf 0)"
  task_warnings="$(jq -r '.summary.combined.warnings // 0' "$work/tasks.json" 2>/dev/null || printf 0)"
  if [[ $CAPTURE_EXIT -eq 0 && "$task_errors" -eq 0 ]]; then
    task_ok=true
  elif (( task_errors > 0 )); then
    task_failure_reason=audit_errors
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
    backup_failure_reason=none
  elif [[ "$backup_result" != succeeded ]]; then
    backup_failure_reason=failed
  elif (( backup_age_seconds < 0 )); then
    backup_failure_reason=invalid_timestamp
  else
    backup_failure_reason=stale
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

actionable_failures=()
if [[ "$gateway_service_ok" != true ]]; then
  actionable_failures+=(gateway_service)
elif [[ "$gateway_ok" != true && "$status_ok" != true ]]; then
  actionable_failures+=(gateway_unresponsive)
fi
(( channel_probe_failures > 0 )) && actionable_failures+=(channel_probe)
(( security_critical > 0 )) && actionable_failures+=(security_critical)
(( secrets_findings > 0 )) && actionable_failures+=(secrets_findings)
[[ "$cron_scheduler_confirmed_disabled" == true ]] && actionable_failures+=(cron_scheduler)
(( cron_recent_failures > 0 )) && actionable_failures+=(cron_job_recent)
(( task_errors > 0 )) && actionable_failures+=(task_errors)
actionable_failures_json="$(jq -nc --args '$ARGS.positional' "${actionable_failures[@]}")"

for result in \
  "$gateway_ok" "$gateway_service_ok" "$status_ok" "$doctor_ok" "$channel_ok" \
  "$security_ok" "$secrets_ok" "$cron_ok" "$task_ok" "$backup_ok"; do
  if [[ "$result" != true && $exit_code -eq 0 ]]; then
    exit_code=1
  fi
done
check_duration_ms=$(($(date +%s%3N) - check_started_ms))

payload="$(jq -nc \
  --arg event health \
  --argjson schemaVersion 2 \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson checkDurationMs "$check_duration_ms" \
  --argjson actionableFailures "$actionable_failures_json" \
  --argjson gatewayOk "$gateway_ok" \
  --argjson gatewayProbeAttempts "$gateway_probe_attempts" \
  --argjson gatewayProbeDurationMs "$gateway_probe_duration_ms" \
  --arg gatewayFailureReason "$gateway_failure_reason" \
  --argjson gatewayServiceOk "$gateway_service_ok" \
  --arg gatewayActiveState "$gateway_active_state" \
  --arg gatewayResult "$gateway_result" \
  --argjson gatewayRestarts "$gateway_restarts" \
  --argjson statusOk "$status_ok" \
  --arg statusFailureReason "$status_failure_reason" \
  --argjson statusDurationMs "$status_duration_ms" \
  --argjson doctorOk "$doctor_ok" \
  --arg doctorFailureReason "$doctor_failure_reason" \
  --argjson doctorDurationMs "$doctor_duration_ms" \
  --argjson channelOk "$channel_ok" \
  --argjson channelProbeFailures "$channel_probe_failures" \
  --arg channelFailureReason "$channel_failure_reason" \
  --argjson channelDurationMs "$channel_duration_ms" \
  --argjson securityOk "$security_ok" \
  --argjson securityCritical "$security_critical" \
  --argjson securityWarnings "$security_warnings" \
  --arg securityFailureReason "$security_failure_reason" \
  --argjson securityDurationMs "$security_duration_ms" \
  --argjson secretsOk "$secrets_ok" \
  --argjson secretsFindings "$secrets_findings" \
  --arg secretsFailureReason "$secrets_failure_reason" \
  --argjson secretsDurationMs "$secrets_duration_ms" \
  --argjson cronOk "$cron_ok" \
  --argjson cronSchedulerOk "$cron_scheduler_ok" \
  --argjson cronSchedulerConfirmedDisabled "$cron_scheduler_confirmed_disabled" \
  --argjson cronStateOk "$cron_state_ok" \
  --argjson cronJobs "$cron_jobs" \
  --argjson cronFailures "$cron_failures" \
  --argjson cronRecentFailures "$cron_recent_failures" \
  --arg cronSchedulerFailureReason "$cron_scheduler_failure_reason" \
  --arg cronStateFailureReason "$cron_state_failure_reason" \
  --argjson cronSchedulerDurationMs "$cron_scheduler_duration_ms" \
  --argjson cronStateDurationMs "$cron_state_duration_ms" \
  --argjson taskOk "$task_ok" \
  --argjson taskErrors "$task_errors" \
  --argjson taskWarnings "$task_warnings" \
  --arg taskFailureReason "$task_failure_reason" \
  --argjson taskDurationMs "$task_duration_ms" \
  --argjson backupOk "$backup_ok" \
  --argjson backupAgeSeconds "$backup_age_seconds" \
  --arg backupFailureReason "$backup_failure_reason" \
  --argjson memoryUsedPercent "$memory_used_percent" \
  --argjson memoryAvailableBytes "$memory_available_bytes" \
  --argjson swapUsedPercent "$swap_used_percent" \
  --argjson swapUsedBytes "$swap_used_bytes" \
  --argjson diskPercent "$disk_percent" \
  --arg diskLevel "$disk_level" \
  '{
    event:$event,schemaVersion:$schemaVersion,timestamp:$timestamp,
    checkDurationMs:$checkDurationMs,actionableFailures:$actionableFailures,
    gatewayOk:$gatewayOk,gatewayProbeAttempts:$gatewayProbeAttempts,
    gatewayProbeDurationMs:$gatewayProbeDurationMs,
    gatewayFailureReason:$gatewayFailureReason,
    gatewayServiceOk:$gatewayServiceOk,
    gatewayActiveState:$gatewayActiveState,gatewayResult:$gatewayResult,
    gatewayRestarts:$gatewayRestarts,statusOk:$statusOk,
    statusFailureReason:$statusFailureReason,statusDurationMs:$statusDurationMs,
    doctorOk:$doctorOk,doctorFailureReason:$doctorFailureReason,
    doctorDurationMs:$doctorDurationMs,channelOk:$channelOk,
    channelProbeFailures:$channelProbeFailures,
    channelFailureReason:$channelFailureReason,channelDurationMs:$channelDurationMs,
    securityOk:$securityOk,securityCritical:$securityCritical,
    securityWarnings:$securityWarnings,securityFailureReason:$securityFailureReason,
    securityDurationMs:$securityDurationMs,secretsOk:$secretsOk,
    secretsFindings:$secretsFindings,secretsFailureReason:$secretsFailureReason,
    secretsDurationMs:$secretsDurationMs,cronOk:$cronOk,
    cronSchedulerOk:$cronSchedulerOk,
    cronSchedulerConfirmedDisabled:$cronSchedulerConfirmedDisabled,
    cronStateOk:$cronStateOk,
    cronJobs:$cronJobs,cronFailures:$cronFailures,
    cronRecentFailures:$cronRecentFailures,
    cronSchedulerFailureReason:$cronSchedulerFailureReason,
    cronStateFailureReason:$cronStateFailureReason,
    cronSchedulerDurationMs:$cronSchedulerDurationMs,
    cronStateDurationMs:$cronStateDurationMs,taskOk:$taskOk,
    taskErrors:$taskErrors,taskWarnings:$taskWarnings,
    taskFailureReason:$taskFailureReason,taskDurationMs:$taskDurationMs,
    backupOk:$backupOk,backupAgeSeconds:$backupAgeSeconds,
    backupFailureReason:$backupFailureReason,
    memoryUsedPercent:$memoryUsedPercent,memoryAvailableBytes:$memoryAvailableBytes,
    swapUsedPercent:$swapUsedPercent,swapUsedBytes:$swapUsedBytes,
    diskPercent:$diskPercent,diskLevel:$diskLevel
  }')"
printf '%s\n' "$payload"
if (( exit_code == 0 )); then
  logger --size 8192 -t openclaw-health -p local6.notice -- "$payload"
else
  logger --size 8192 -t openclaw-health -p local6.warning -- "$payload"
fi
exit "$exit_code"
