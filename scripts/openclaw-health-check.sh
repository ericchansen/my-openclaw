#!/usr/bin/env bash
set -Eeuo pipefail

gateway_url="${OPENCLAW_HEALTH_URL:-http://127.0.0.1:18789/health}"
backup_status="${OPENCLAW_BACKUP_STATUS:-/var/lib/openclaw-runtime/backup-status.json}"
backup_max_age_seconds="${OPENCLAW_BACKUP_MAX_AGE_SECONDS:-129600}"
health_state_dir="${OPENCLAW_HEALTH_STATE_DIR:-/var/lib/openclaw-runtime/health}"
runtime_root="${RUNTIME_DIRECTORY:-$health_state_dir}"
automation_recent_failure_seconds="${OPENCLAW_AUTOMATION_RECENT_FAILURE_SECONDS:-7200}"
automation_failure_threshold="${OPENCLAW_AUTOMATION_FAILURE_THRESHOLD:-1}"
capture_max_bytes=2097152
umask 077

task_settlement_max_age_seconds="${OPENCLAW_TASK_SETTLEMENT_MAX_AGE_SECONDS-2400}"
if [[ ! "$task_settlement_max_age_seconds" =~ ^[1-9][0-9]{0,3}$ ]] ||
  (( task_settlement_max_age_seconds < 60 || task_settlement_max_age_seconds > 3600 )); then
  printf 'Invalid task settlement age threshold (integer 60..3600 seconds required).\n' >&2
  exit 64
fi

capacity_memory_percent="${OPENCLAW_CAPACITY_MEMORY_PERCENT-85}"
capacity_swap_percent="${OPENCLAW_CAPACITY_SWAP_PERCENT-80}"
capacity_memory_some_avg60="${OPENCLAW_CAPACITY_MEMORY_SOME_AVG60-10}"
capacity_memory_full_avg60="${OPENCLAW_CAPACITY_MEMORY_FULL_AVG60-2}"
capacity_cpu_some_avg60="${OPENCLAW_CAPACITY_CPU_SOME_AVG60-25}"

validate_capacity_thresholds() {
  local spec name minimum maximum value
  for spec in \
    capacity_memory_percent:70:99 capacity_swap_percent:50:99 \
    capacity_memory_some_avg60:1:100 capacity_memory_full_avg60:1:100 \
    capacity_cpu_some_avg60:5:100; do
    IFS=: read -r name minimum maximum <<<"$spec"
    value="${!name}"
    if [[ ! "$value" =~ ^[1-9][0-9]{0,2}$ ]] ||
      (( value < minimum || value > maximum )); then
      printf 'Invalid capacity threshold: %s (integer %s..%s required).\n' \
        "$name" "$minimum" "$maximum" >&2
      return 64
    fi
  done
  if (( capacity_memory_full_avg60 > capacity_memory_some_avg60 )); then
    printf 'Memory full PSI threshold must not exceed memory some PSI threshold.\n' >&2
    return 64
  fi
}

read_psi_avg60() {
  local path="$1" category="$2" value
  value="$(
    { head -c 4096 -- "$path" 2>/dev/null || true; } |
      LC_ALL=C awk -v category="$category" '
        $1 == category {
          for (i = 2; i <= NF; i++) {
            if ($i ~ /^avg60=[0-9]+([.][0-9]+)?$/) {
              split($i, pair, "=")
              if (pair[2] + 0 <= 100) { value = pair[2] + 0; count++ }
            }
          }
        }
        END { if (count == 1) printf "%.2f", value }
      '
  )"
  printf '%s' "${value:-null}"
}

sample_capacity() {
  local proc_root="${1:-/proc}" memory_some memory_full cpu_some
  memory_total_bytes=0
  memory_available_bytes=0
  swap_total_bytes=0
  swap_free_bytes=0
  memory_metrics_available=false
  read -r memory_total_bytes memory_available_bytes swap_total_bytes swap_free_bytes < <(
    { head -c 16384 -- "$proc_root/meminfo" 2>/dev/null || true; } |
      LC_ALL=C awk '
        $1 ~ /^(MemTotal:|MemAvailable:|SwapTotal:|SwapFree:)$/ &&
          $2 ~ /^[0-9]+$/ && $3 == "kB" { values[$1] = $2; count++ }
        END {
          if (count == 4 && ("MemTotal:" in values) && ("MemAvailable:" in values) &&
              ("SwapTotal:" in values) && ("SwapFree:" in values) && values["MemTotal:"] > 0 &&
              values["MemAvailable:"] <= values["MemTotal:"] &&
              values["SwapFree:"] <= values["SwapTotal:"])
            printf "%.0f %.0f %.0f %.0f\n", values["MemTotal:"] * 1024,
              values["MemAvailable:"] * 1024, values["SwapTotal:"] * 1024,
              values["SwapFree:"] * 1024
        }
      '
  ) || true
  memory_total_bytes="${memory_total_bytes:-0}"
  memory_available_bytes="${memory_available_bytes:-0}"
  swap_total_bytes="${swap_total_bytes:-0}"
  swap_free_bytes="${swap_free_bytes:-0}"
  memory_used_percent=0
  swap_used_bytes=$((swap_total_bytes - swap_free_bytes))
  swap_used_percent=0
  if (( memory_total_bytes > 0 )); then
    memory_metrics_available=true
    memory_used_percent=$(((memory_total_bytes - memory_available_bytes) * 100 / memory_total_bytes))
  fi
  if (( swap_total_bytes > 0 )); then
    swap_used_percent=$((swap_used_bytes * 100 / swap_total_bytes))
  fi
  memory_some="$(read_psi_avg60 "$proc_root/pressure/memory" some)"
  memory_full="$(read_psi_avg60 "$proc_root/pressure/memory" full)"
  cpu_some="$(read_psi_avg60 "$proc_root/pressure/cpu" some)"
  capacity_json="$(jq -nc \
    --arg sampledAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson memoryMetricsAvailable "$memory_metrics_available" \
    --argjson memoryUsedPercent "$memory_used_percent" \
    --argjson swapUsedPercent "$swap_used_percent" \
    --argjson swapTotalBytes "$swap_total_bytes" \
    --argjson memorySome "$memory_some" --argjson memoryFull "$memory_full" \
    --argjson cpuSome "$cpu_some" \
    --argjson memoryThreshold "$capacity_memory_percent" \
    --argjson swapThreshold "$capacity_swap_percent" \
    --argjson memorySomeThreshold "$capacity_memory_some_avg60" \
    --argjson memoryFullThreshold "$capacity_memory_full_avg60" \
    --argjson cpuSomeThreshold "$capacity_cpu_some_avg60" '
    [
      if $memoryMetricsAvailable and $swapTotalBytes > 0 and
        $memoryUsedPercent >= $memoryThreshold and $swapUsedPercent >= $swapThreshold
        then "memory_swap_pressure" else empty end,
      if $memorySome != null and $memorySome >= $memorySomeThreshold
        then "memory_psi_some" else empty end,
      if $memoryFull != null and $memoryFull >= $memoryFullThreshold
        then "memory_psi_full" else empty end,
      if $cpuSome != null and $cpuSome >= $cpuSomeThreshold
        then "cpu_psi_some" else empty end
    ] as $reasons |
    [
      if $memoryMetricsAvailable then empty else "memory_usage" end,
      if $memorySome == null then "memory_psi_some" else empty end,
      if $memoryFull == null then "memory_psi_full" else empty end,
      if $cpuSome == null then "cpu_psi_some" else empty end
    ] as $unavailable |
    {
      sampledAt:$sampledAt, pressure:($reasons | length > 0),
      state:(if ($reasons | length) > 0 then "pressure"
        elif ($unavailable | length) > 0 then "unavailable" else "normal" end),
      reasons:$reasons, unavailableSignals:$unavailable,
      memoryMetricsAvailable:$memoryMetricsAvailable,
      memorySomeAvg60Percent:$memorySome, memoryFullAvg60Percent:$memoryFull,
      cpuSomeAvg60Percent:$cpuSome,
      thresholds:{
        memoryUsedPercent:$memoryThreshold, swapUsedPercent:$swapThreshold,
        memorySomeAvg60Percent:$memorySomeThreshold,
        memoryFullAvg60Percent:$memoryFullThreshold, cpuSomeAvg60Percent:$cpuSomeThreshold
      }
    }')"
  capacity_pressure="$(jq -r '.pressure' <<<"$capacity_json")"
}

validate_capacity_thresholds

summarize_task_settlement() {
  # TaskRecord timestamps are epoch milliseconds. Match isTerminalTaskStatus,
  # not gateway display statuses; lastEventAt also records legitimate redrives.
  jq -s -e --argjson nowMs "$2" --argjson maxAgeMs "$((task_settlement_max_age_seconds * 1000))" '
    def integer: type == "number" and floor == .;
    def token: type == "string" and test("\\S");
    def timestamp: integer and . > 0 and . <= $nowMs;
    def is_terminal: . == "succeeded" or . == "failed" or . == "timed_out" or
      . == "cancelled" or . == "lost";
    if length != 1 then error("invalid_inventory") else .[0] end |
    if type != "object" then error("invalid_inventory") else . end |
    if (.runtime != "subagent" or (has("status") | not) or .status != null or
        (.tasks | type != "array") or (.count | integer | not))
      then error("invalid_inventory") else . end |
    if .count != (.tasks | length) or
      ([.tasks[].taskId] | unique | length) != .count or
      (all(.tasks[];
        type == "object" and (.taskId | token) and .runtime == "subagent" and
        (.status | . == "queued" or . == "running" or is_terminal) and
        (.deliveryStatus | . == "pending" or . == "session_queued" or . == "delivered" or
          . == "failed" or . == "dismissed" or . == "parent_missing" or . == "not_applicable") and
        (.notifyPolicy | . == "done_only" or . == "state_changes" or . == "silent") and
        (.scopeKind == "session" or .scopeKind == "system") and
        (.ownerKey | type == "string") and (.requesterSessionKey | type == "string") and
        (.createdAt | timestamp)
      ) | not) then error("invalid_inventory") else . end |
    .count as $inventoryCount |
    [.tasks[] | select((.status | is_terminal) and
      (.deliveryStatus == "pending" or .deliveryStatus == "session_queued") and
      .notifyPolicy != "silent" and .scopeKind == "session") |
      if ((.runId | token) and (.childSessionKey | token) and
          (.ownerKey | token) and (.requesterSessionKey | token) | not)
        then {unknown:"uncorrelated_terminal_pending"}
      elif ((.endedAt | timestamp) and .endedAt >= .createdAt and
          (if has("startedAt") then
            (.startedAt | timestamp) and .startedAt >= .createdAt and .startedAt <= .endedAt
            else true end) and
          (if has("lastEventAt") then
            (.lastEventAt | timestamp) and .lastEventAt >= .endedAt else true end) | not)
        then {unknown:"invalid_timestamp"}
      else {ageMs:($nowMs - ([.endedAt, .lastEventAt | select(. != null)] | max))}
      end
    ] as $pending |
    [$pending[] | select(has("ageMs")) | .ageMs] as $ages |
    [$ages[] | select(. > $maxAgeMs)] as $stale |
    [$pending[] | select(has("unknown")) | .unknown] as $unknown |
    {
      ok:(if ($stale | length) > 0 then false
        elif ($unknown | length) > 0 then null else true end),
      count:($stale | length), pendingCount:($pending | length),
      inventoryCount:$inventoryCount, unknownCount:($unknown | length),
      oldestAgeSeconds:(if ($ages | length) > 0 then ($ages | max / 1000 | floor) else null end),
      failureReason:(if ($stale | length) > 0 then "stale_terminal_pending"
        elif ($unknown | length) > 0 then ($unknown | sort | first) else "none" end)
    }
  ' "$1"
}

maintenance_lock=/etc/openclaw/maintenance.lock
[[ -d /etc/openclaw && ! -L /etc/openclaw &&
  "$(stat -c '%u:%g:%a' /etc/openclaw)" == 0:0:755 &&
  -f "$maintenance_lock" && ! -L "$maintenance_lock" &&
  "$(stat -c '%u:%g:%a:%h' "$maintenance_lock")" == 0:0:644:1 ]] || {
  printf 'OpenClaw maintenance lock is missing or unsafe.\n' >&2
  exit 78
}
exec 8<"$maintenance_lock"
flock --shared --nonblock --conflict-exit-code 75 8 || {
  lock_status=$?
  (( lock_status == 75 )) || exit "$lock_status"
  printf '%s\n' '{"event":"health_skipped","reason":"maintenance"}'
  exit 0
}

[[ "$automation_recent_failure_seconds" =~ ^[0-9]+$ ]] || exit 64
[[ "$automation_failure_threshold" =~ ^[1-9][0-9]*$ ]] || exit 64
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

# Emit the cheap sample before canaries/audits can time out. It is not a complete
# schema-v2 health record and must not reset the existing missing-health alert.
sample_capacity
capacity_payload="$(jq -nc --argjson capacity "$capacity_json" \
  --argjson memoryUsedPercent "$memory_used_percent" \
  --argjson memoryAvailableBytes "$memory_available_bytes" \
  --argjson swapUsedPercent "$swap_used_percent" --argjson swapUsedBytes "$swap_used_bytes" '
  {event:"capacity",capacitySchemaVersion:1,timestamp:$capacity.sampledAt,capacity:$capacity,
    memoryUsedPercent:$memoryUsedPercent,memoryAvailableBytes:$memoryAvailableBytes,
    swapUsedPercent:$swapUsedPercent,swapUsedBytes:$swapUsedBytes}')"
capacity_priority=notice
[[ "$capacity_pressure" != true ]] || capacity_priority=warning
timeout --signal=TERM --kill-after=1s 3s logger --size 8192 -t openclaw-health \
  -p "local6.$capacity_priority" -- "$capacity_payload" ||
  printf 'Early capacity telemetry could not be delivered.\n' >&2

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
  if [[ -s "$output" ]] && jq -e 'type == "object"' "$output" >/dev/null 2>&1; then
    CAPTURE_VALID=true
  fi
  if (( pipeline_status[1] != 0 || output_bytes >= capture_max_bytes )); then
    CAPTURE_EXIT=1
    CAPTURE_REASON=output_limit
  elif (( CAPTURE_EXIT == 124 )); then
    CAPTURE_REASON=timeout
  elif (( CAPTURE_EXIT == 137 )); then
    CAPTURE_REASON=terminated
  elif (( CAPTURE_EXIT != 0 )); then
    CAPTURE_REASON=command_exit
  elif [[ ! -s "$output" ]]; then
    CAPTURE_REASON=empty_output
  elif [[ "$CAPTURE_VALID" != true ]]; then
    CAPTURE_REASON=invalid_json
  fi
}

gateway_ok=false
status_ok=false
doctor_ok=false
channel_ok=false
security_ok=false
secrets_ok=false
automation_ok=false
automation_scheduler_ok=false
automation_scheduler_confirmed_disabled=false
automation_state_ok=false
task_ok=false
task_audit_ok=false
task_settlement_ok=null
task_settlement_count=null
task_settlement_pending_count=null
task_settlement_inventory_count=null
task_settlement_unknown_count=null
task_settlement_oldest_age_seconds=null
task_settlement_failure_reason=not_run
task_settlement_duration_ms=0
backup_ok=false
gateway_service_ok=false
availability_ok=false
availability_failure_reason=not_run

gateway_probe_attempts=0
gateway_probe_duration_ms=0
gateway_failure_reason=not_run
status_failure_reason=not_run
doctor_failure_reason=not_run
channel_failure_reason=not_run
security_failure_reason=not_run
secrets_failure_reason=not_run
automation_scheduler_failure_reason=not_run
automation_state_failure_reason=not_run
task_failure_reason=not_run
backup_failure_reason=missing

status_duration_ms=0
doctor_duration_ms=0
channel_duration_ms=0
security_duration_ms=0
secrets_duration_ms=0
automation_scheduler_duration_ms=0
automation_state_duration_ms=0
task_duration_ms=0

channel_probe_failures=0
security_critical=0
security_warnings=0
secrets_findings=0
automation_jobs=0
automation_failures=0
automation_recent_failures=0
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

capture_json availability 110 python3 /usr/local/libexec/openclaw-availability-check \
  --status-file "$health_state_dir/availability.json"
availability_failure_reason="$CAPTURE_REASON"
if [[ "$CAPTURE_VALID" == true && $CAPTURE_EXIT -eq 0 ]] &&
  jq -e '.ok == true' "$work/availability.json" >/dev/null; then
  availability_ok=true
elif [[ "$CAPTURE_VALID" == true ]]; then
  availability_failure_reason="$(jq -r '.reason // "invalid_result"' "$work/availability.json")"
fi

capture_json doctor 100 openclaw doctor --lint --json
doctor_duration_ms="$CAPTURE_DURATION_MS"
doctor_failure_reason="$CAPTURE_REASON"
doctor_exit_code="$CAPTURE_EXIT"
doctor_error_checks='[]'
if [[ "$CAPTURE_VALID" == true ]]; then
  if jq -e '.findings | type == "array"' "$work/doctor.json" >/dev/null; then
    doctor_error_checks="$(jq -c '[.findings[]? | select(.severity == "error") |
      .checkId | select(type == "string") |
      select(test("^[A-Za-z0-9/_-]{1,128}$"))] | unique' "$work/doctor.json")"
  else
    doctor_failure_reason=invalid_contract
  fi
fi
if [[ "$CAPTURE_VALID" == true && ( $CAPTURE_EXIT -eq 0 || $CAPTURE_EXIT -eq 1 ) ]] &&
  jq -e '.findings | type == "array" and
    all(.[]; .severity == "warning" or .severity == "info")' "$work/doctor.json" >/dev/null; then
  doctor_ok=true
  doctor_failure_reason=none
fi

capture_json channels 30 openclaw channels status --probe --timeout 15000 --json
channel_duration_ms="$CAPTURE_DURATION_MS"
channel_failure_reason="$CAPTURE_REASON"
if [[ "$CAPTURE_VALID" == true ]] &&
  jq -e '.channelAccounts | type == "object"' "$work/channels.json" >/dev/null; then
  channel_probe_failures="$(jq -r '
    [.channelAccounts // {} | to_entries[]?.value[]? |
      select(.enabled != false and .configured != false) |
      select(
        .running == false or .connected == false or
        (.probe? != null and .probe.ok != true)
      )] | length
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

capture_json automations 25 openclaw automations status --json
automation_scheduler_duration_ms="$CAPTURE_DURATION_MS"
automation_scheduler_failure_reason="$CAPTURE_REASON"
if [[ "$CAPTURE_VALID" == true ]]; then
  if jq -e '
    type == "object" and
    (.enabled | type == "boolean") and
    (.triggersEnabled | type == "boolean") and
    (.storage == "sqlite") and
    (.jobs | type == "number" and . >= 0 and floor == .) and
    (.nextWakeAtMs == null or (.nextWakeAtMs | type == "number" and . >= 0))
  ' "$work/automations.json" >/dev/null 2>&1; then
    automation_jobs="$(jq -r '.jobs' "$work/automations.json")"
    automation_enabled="$(jq -r '.enabled' "$work/automations.json")"
    automation_triggers_enabled="$(jq -r '.triggersEnabled' "$work/automations.json")"
  else
    automation_enabled=invalid
    automation_triggers_enabled=invalid
    automation_scheduler_failure_reason=invalid_contract
  fi
  if [[ $CAPTURE_EXIT -eq 0 && "$automation_enabled" == true &&
    "$automation_triggers_enabled" == true ]]; then
    automation_scheduler_ok=true
  elif [[ "$automation_enabled" == false ]]; then
    automation_scheduler_confirmed_disabled=true
    automation_scheduler_failure_reason=disabled
  elif [[ "$automation_triggers_enabled" == false ]]; then
    automation_scheduler_failure_reason=triggers_disabled
  fi
fi

capture_json automation_list 25 openclaw automations list --all --json
automation_state_duration_ms="$CAPTURE_DURATION_MS"
automation_state_failure_reason="$CAPTURE_REASON"
if [[ "$CAPTURE_VALID" == true && $CAPTURE_EXIT -eq 0 ]] && jq -e '
  type == "object" and
  (.jobs | type == "array") and
  all(.jobs[];
    type == "object" and
    (.id | type == "string" and length > 0) and
    (.enabled | type == "boolean") and
    (.schedule | type == "object") and
    (.payload | type == "object") and
    (.state | type == "object")
  ) and
  (.total | type == "number" and floor == .) and
  (.total == (.jobs | length)) and
  (.offset | type == "number" and . >= 0 and floor == .) and
  (.limit | type == "number" and . >= 1 and floor == .) and
  (.hasMore == false) and
  (.nextOffset == null)
' "$work/automation_list.json" >/dev/null 2>&1; then
  automation_state_ok=true
  automation_failures="$(jq -r '[
    .jobs[]? | select(.enabled == true and ((.state.consecutiveErrors // 0) > 0))
  ] | length' "$work/automation_list.json" 2>/dev/null || printf 0)"
  automation_recent_failures="$(jq -r \
    --argjson nowMs "$now_ms" \
    --argjson windowMs "$((automation_recent_failure_seconds * 1000))" \
    --argjson threshold "$automation_failure_threshold" '
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
  ' "$work/automation_list.json" 2>/dev/null || printf 0)"
  if (( automation_recent_failures > 0 )); then
    automation_state_failure_reason=recent_repeated_errors
  fi
elif [[ "$CAPTURE_VALID" == true && $CAPTURE_EXIT -eq 0 ]]; then
  automation_state_failure_reason=invalid_contract
fi
if [[ "$automation_scheduler_ok" == true && "$automation_state_ok" == true &&
  "$automation_recent_failures" -eq 0 ]]; then
  automation_ok=true
fi

capture_json tasks 25 openclaw tasks audit --json
task_duration_ms="$CAPTURE_DURATION_MS"
task_failure_reason="$CAPTURE_REASON"
if [[ "$CAPTURE_VALID" == true ]] && jq -se '
  length == 1 and all(.[]; .summary.combined |
    (.errors | type == "number" and . >= 0 and floor == .) and
    (.warnings | type == "number" and . >= 0 and floor == .))
' "$work/tasks.json" >/dev/null 2>&1; then
  task_errors="$(jq -r '.summary.combined.errors' "$work/tasks.json")"
  task_warnings="$(jq -r '.summary.combined.warnings' "$work/tasks.json")"
  if [[ $CAPTURE_EXIT -eq 0 && "$task_errors" -eq 0 ]]; then
    task_audit_ok=true
  elif (( task_errors > 0 )); then
    task_failure_reason=audit_errors
  fi
elif [[ "$CAPTURE_VALID" == true && $CAPTURE_EXIT -eq 0 ]]; then
  task_failure_reason=invalid_contract
fi

capture_json task_settlement 25 openclaw tasks list --runtime subagent --json
task_settlement_duration_ms="$CAPTURE_DURATION_MS"
task_settlement_failure_reason="$CAPTURE_REASON"
if [[ "$CAPTURE_VALID" == true && $CAPTURE_EXIT -eq 0 ]]; then
  if summarize_task_settlement "$work/task_settlement.json" "$(date +%s%3N)" \
    >"$work/task_settlement_summary.json" 2>/dev/null; then
    read -r task_settlement_ok task_settlement_count task_settlement_pending_count \
      task_settlement_inventory_count task_settlement_unknown_count \
      task_settlement_oldest_age_seconds task_settlement_failure_reason < <(
      jq -r '[.ok,.count,.pendingCount,.inventoryCount,.unknownCount,.oldestAgeSeconds,.failureReason] |
        map(tostring) | @tsv' "$work/task_settlement_summary.json"
    )
  else
    task_settlement_failure_reason=invalid_inventory
  fi
fi
if [[ "$task_audit_ok" == true && "$task_settlement_ok" == true ]]; then
  task_ok=true
elif [[ "$task_audit_ok" == true ]]; then
  task_failure_reason=settlement_unknown
  [[ "$task_settlement_ok" != false ]] || task_failure_reason=stale_settlement
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
if [[ "$capacity_pressure" == true ]]; then
  actionable_failures+=(capacity_pressure)
  (( exit_code != 0 )) || exit_code=1
fi
if [[ "$gateway_service_ok" != true ]]; then
  actionable_failures+=(gateway_service)
elif [[ "$gateway_ok" != true && "$status_ok" != true ]]; then
  actionable_failures+=(gateway_unresponsive)
fi
[[ "$channel_ok" == true ]] || actionable_failures+=(channel_probe)
[[ "$availability_ok" == true ]] || actionable_failures+=(application_canary)
[[ "$doctor_ok" == true ]] || actionable_failures+=(doctor)
[[ "$automation_state_ok" == true ]] || actionable_failures+=(automation_state)
[[ "$backup_ok" == true ]] || actionable_failures+=(backup_status)
(( security_critical > 0 )) && actionable_failures+=(security_critical)
(( secrets_findings > 0 )) && actionable_failures+=(secrets_findings)
if [[ "$automation_scheduler_failure_reason" == disabled ||
  "$automation_scheduler_failure_reason" == triggers_disabled ]]; then
  actionable_failures+=(automation_scheduler)
fi
(( automation_recent_failures > 0 )) && actionable_failures+=(automation_job_recent)
(( task_errors > 0 )) && actionable_failures+=(task_errors)
[[ "$task_settlement_ok" != false ]] || actionable_failures+=(task-settlement)
actionable_failures_json="$(jq -nc --args '$ARGS.positional' "${actionable_failures[@]}")"

for result in \
  "$gateway_ok" "$gateway_service_ok" "$status_ok" "$doctor_ok" "$channel_ok" \
  "$security_ok" "$secrets_ok" "$automation_ok" "$task_ok" "$backup_ok" "$availability_ok"; do
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
  --argjson capacity "$capacity_json" \
  --argjson availabilityOk "$availability_ok" \
  --arg availabilityFailureReason "$availability_failure_reason" \
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
  --argjson doctorExitCode "$doctor_exit_code" \
  --argjson doctorErrorChecks "$doctor_error_checks" \
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
  --argjson cronOk "$automation_ok" \
  --argjson cronSchedulerOk "$automation_scheduler_ok" \
  --argjson cronSchedulerConfirmedDisabled "$automation_scheduler_confirmed_disabled" \
  --argjson cronStateOk "$automation_state_ok" \
  --argjson cronJobs "$automation_jobs" \
  --argjson cronFailures "$automation_failures" \
  --argjson cronRecentFailures "$automation_recent_failures" \
  --arg cronSchedulerFailureReason "$automation_scheduler_failure_reason" \
  --arg cronStateFailureReason "$automation_state_failure_reason" \
  --argjson cronSchedulerDurationMs "$automation_scheduler_duration_ms" \
  --argjson cronStateDurationMs "$automation_state_duration_ms" \
  --argjson taskOk "$task_ok" \
  --argjson taskAuditOk "$task_audit_ok" \
  --argjson taskSettlementOk "$task_settlement_ok" \
  --argjson taskSettlementCount "$task_settlement_count" \
  --argjson taskSettlementPendingCount "$task_settlement_pending_count" \
  --argjson taskSettlementInventoryCount "$task_settlement_inventory_count" \
  --argjson taskSettlementUnknownCount "$task_settlement_unknown_count" \
  --argjson taskSettlementOldestAgeSeconds "$task_settlement_oldest_age_seconds" \
  --arg taskSettlementFailureReason "$task_settlement_failure_reason" \
  --argjson taskSettlementDurationMs "$task_settlement_duration_ms" \
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
    checkDurationMs:$checkDurationMs,actionableFailures:$actionableFailures,capacity:$capacity,
    availabilityOk:$availabilityOk,availabilityFailureReason:$availabilityFailureReason,
    gatewayOk:$gatewayOk,gatewayProbeAttempts:$gatewayProbeAttempts,
    gatewayProbeDurationMs:$gatewayProbeDurationMs,
    gatewayFailureReason:$gatewayFailureReason,
    gatewayServiceOk:$gatewayServiceOk,
    gatewayActiveState:$gatewayActiveState,gatewayResult:$gatewayResult,
    gatewayRestarts:$gatewayRestarts,statusOk:$statusOk,
    statusFailureReason:$statusFailureReason,statusDurationMs:$statusDurationMs,
    doctorOk:$doctorOk,doctorFailureReason:$doctorFailureReason,
    doctorExitCode:$doctorExitCode,doctorErrorChecks:$doctorErrorChecks,
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
    taskAuditOk:$taskAuditOk,taskSettlementOk:$taskSettlementOk,
    taskSettlementCount:$taskSettlementCount,taskSettlementPendingCount:$taskSettlementPendingCount,
    taskSettlementInventoryCount:$taskSettlementInventoryCount,
    taskSettlementUnknownCount:$taskSettlementUnknownCount,
    taskSettlementOldestAgeSeconds:$taskSettlementOldestAgeSeconds,
    taskSettlementFailureReason:$taskSettlementFailureReason,
    taskSettlementDurationMs:$taskSettlementDurationMs,
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
