#!/usr/bin/env bash
set -Eeuo pipefail

readonly gateway_url="${OPENCLAW_GATEWAY_HEALTH_URL:-http://127.0.0.1:18789/health}"
readonly proc_root="${OPENCLAW_PROC_ROOT:-/proc}"
readonly disk_pressure_percent=85
readonly memory_pressure_percent=90
umask 077

gateway_endpoint_ok=false
if timeout --signal=TERM --kill-after=1s 3s \
  curl --silent --show-error --fail --max-time 2 --output /dev/null "$gateway_url" 2>/dev/null; then
  gateway_endpoint_ok=true
fi

gateway_service_ok=false
gateway_active_state=unknown
gateway_result=unknown
service_output="$(
  timeout --signal=TERM --kill-after=1s 2s \
    systemctl show openclaw-gateway.service \
      --property=ActiveState --property=Result 2>/dev/null
)" || service_output=
while IFS='=' read -r key value; do
  case "$key" in
    ActiveState) gateway_active_state="$value" ;;
    Result) gateway_result="$value" ;;
  esac
done <<<"$service_output"
[[ "$gateway_active_state" == active && "$gateway_result" == success ]] && gateway_service_ok=true

memory_total_kib=0
memory_available_kib=0
read -r memory_total_kib memory_available_kib < <(
  awk '
    $1 == "MemTotal:" && $2 ~ /^[0-9]+$/ { total=$2 }
    $1 == "MemAvailable:" && $2 ~ /^[0-9]+$/ { available=$2 }
    END { if (total > 0 && available >= 0 && available <= total) print total, available }
  ' "$proc_root/meminfo" 2>/dev/null
) || true
memory_metrics_ok=false
memory_used_percent=0
if (( memory_total_kib > 0 )); then
  memory_metrics_ok=true
  memory_used_percent=$(((memory_total_kib - memory_available_kib) * 100 / memory_total_kib))
fi

load_metrics_ok=false
load1=0
cpu_count="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
read -r load1 _ < "$proc_root/loadavg" 2>/dev/null || true
if [[ "$cpu_count" =~ ^[1-9][0-9]*$ && "$load1" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  load_metrics_ok=true
else
  cpu_count=0
  load1=0
fi

disk_metrics_ok=false
disk_used_percent="$(df --output=pcent / 2>/dev/null | tail -n 1 | tr -cd '0-9')"
if [[ "$disk_used_percent" =~ ^[0-9]+$ ]] && (( disk_used_percent <= 100 )); then
  disk_metrics_ok=true
else
  disk_used_percent=0
fi

capacity_pressure=false
if [[ "$memory_metrics_ok" == true && "$load_metrics_ok" == true ]] &&
  awk -v memory="$memory_used_percent" -v memory_limit="$memory_pressure_percent" \
    -v load_value="$load1" -v cpus="$cpu_count" \
    'BEGIN { exit ! (memory >= memory_limit || load_value >= cpus) }'; then
  capacity_pressure=true
fi
disk_pressure=false
(( disk_used_percent >= disk_pressure_percent )) && disk_pressure=true

probe_ok=false
if [[ "$gateway_endpoint_ok" == true && "$gateway_service_ok" == true &&
  "$memory_metrics_ok" == true && "$load_metrics_ok" == true &&
  "$disk_metrics_ok" == true && "$capacity_pressure" == false &&
  "$disk_pressure" == false ]]; then
  probe_ok=true
fi

payload="$(jq -nc \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson probeOk "$probe_ok" \
  --argjson gatewayEndpointOk "$gateway_endpoint_ok" \
  --argjson gatewayServiceOk "$gateway_service_ok" \
  --arg gatewayActiveState "$gateway_active_state" \
  --arg gatewayResult "$gateway_result" \
  --argjson memoryMetricsOk "$memory_metrics_ok" \
  --argjson memoryUsedPercent "$memory_used_percent" \
  --argjson loadMetricsOk "$load_metrics_ok" \
  --argjson load1 "$load1" \
  --argjson cpuCount "${cpu_count:-0}" \
  --argjson diskMetricsOk "$disk_metrics_ok" \
  --argjson diskUsedPercent "$disk_used_percent" \
  --argjson capacityPressure "$capacity_pressure" \
  --argjson diskPressure "$disk_pressure" \
  '{event:"runtime_health_probe",timestamp:$timestamp,probeOk:$probeOk,
    gateway:{endpointOk:$gatewayEndpointOk,serviceOk:$gatewayServiceOk,
      activeState:$gatewayActiveState,result:$gatewayResult},
    capacity:{memoryMetricsOk:$memoryMetricsOk,memoryUsedPercent:$memoryUsedPercent,
      loadMetricsOk:$loadMetricsOk,load1:$load1,cpuCount:$cpuCount,
      pressure:$capacityPressure},
    disk:{metricsOk:$diskMetricsOk,usedPercent:$diskUsedPercent,pressure:$diskPressure}}'
)"
printf '%s\n' "$payload"
priority=notice
[[ "$probe_ok" == true ]] || priority=warning
timeout --signal=TERM --kill-after=1s 2s \
  logger --size 8192 -t openclaw-runtime-health-probe -p "local6.$priority" -- "$payload" || exit 70
[[ "$probe_ok" == true ]]
