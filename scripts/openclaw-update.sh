#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
  printf 'Run this updater as root.\n' >&2
  exit 77
fi
umask 077

target_version=
verified_backup=
snapshot_evidence=
openclaw_user=azureuser
copilot_version=
mcp_ebird_version=
mcp_pondlog_version=
sandbox_source_commit=
sandbox_archive_url=
sandbox_archive_sha256=
sandbox_browser_contract=
openclaw_integrity=
diagnostics_otel_version=
diagnostics_otel_integrity=
copilot_integrity=
mcp_ebird_integrity=
mcp_pondlog_integrity=
drain_timeout=300
runtime_installer=
runtime_installer_args=()
sandbox_provisioner=/usr/local/sbin/openclaw-provision-sandbox-images

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-version) target_version="$2"; shift 2 ;;
    --verified-backup) verified_backup="$2"; shift 2 ;;
    --snapshot-evidence) snapshot_evidence="$2"; shift 2 ;;
    --user) openclaw_user="$2"; shift 2 ;;
    --copilot-version) copilot_version="$2"; shift 2 ;;
    --mcp-ebird-version) mcp_ebird_version="$2"; shift 2 ;;
    --mcp-pondlog-version) mcp_pondlog_version="$2"; shift 2 ;;
    --sandbox-source-commit) sandbox_source_commit="$2"; shift 2 ;;
    --sandbox-archive-url) sandbox_archive_url="$2"; shift 2 ;;
    --sandbox-archive-sha256) sandbox_archive_sha256="$2"; shift 2 ;;
    --sandbox-browser-contract) sandbox_browser_contract="$2"; shift 2 ;;
    --openclaw-integrity) openclaw_integrity="$2"; shift 2 ;;
    --diagnostics-otel-version) diagnostics_otel_version="$2"; shift 2 ;;
    --diagnostics-otel-integrity) diagnostics_otel_integrity="$2"; shift 2 ;;
    --copilot-integrity) copilot_integrity="$2"; shift 2 ;;
    --mcp-ebird-integrity) mcp_ebird_integrity="$2"; shift 2 ;;
    --mcp-pondlog-integrity) mcp_pondlog_integrity="$2"; shift 2 ;;
    --drain-timeout) drain_timeout="$2"; shift 2 ;;
    --runtime-installer) runtime_installer="$2"; shift 2 ;;
    --sandbox-provisioner) sandbox_provisioner="$2"; shift 2 ;;
    --) shift; runtime_installer_args=("$@"); break ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done

[[ "$target_version" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+$ ]] || {
  printf 'An exact --target-version is required.\n' >&2
  exit 64
}
[[ "$openclaw_user" =~ ^[a-z_][a-z0-9_-]*$ ]] || exit 64
[[ "$drain_timeout" =~ ^[0-9]+$ && "$drain_timeout" -le 1800 ]] || exit 64
snapshot_evidence_lower="${snapshot_evidence,,}"
[[ "$snapshot_evidence_lower" =~ ^/subscriptions/[^/]+/resourcegroups/[^/]+/providers/microsoft\.compute/snapshots/[^/]+$ ]] || {
  printf 'Caller-verified --snapshot-evidence is required.\n' >&2
  exit 64
}
[[ -f "$verified_backup" && ! -L "$verified_backup" ]] || {
  printf 'Verified backup archive is missing or unsafe: %s\n' "$verified_backup" >&2
  exit 66
}
for value in \
  "$diagnostics_otel_version" "$copilot_version" "$mcp_ebird_version" "$mcp_pondlog_version" \
  "$openclaw_integrity" "$diagnostics_otel_integrity" \
  "$copilot_integrity" "$mcp_ebird_integrity" "$mcp_pondlog_integrity" \
  "$sandbox_source_commit" "$sandbox_archive_url" "$sandbox_archive_sha256" \
  "$sandbox_browser_contract"; do
  [[ -n "$value" ]] || {
    printf 'All package versions and registry integrities are required.\n' >&2
    exit 64
  }
done
for version in \
  "$diagnostics_otel_version" "$copilot_version" "$mcp_ebird_version" "$mcp_pondlog_version"; do
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 64
done
[[ "$openclaw_integrity" =~ ^sha512-[A-Za-z0-9+/]+={0,2}$ ]] || exit 64
[[ "$diagnostics_otel_integrity" =~ ^sha512-[A-Za-z0-9+/]+={0,2}$ ]] || exit 64
[[ "$copilot_integrity" =~ ^sha512-[A-Za-z0-9+/]+={0,2}$ ]] || exit 64
[[ "$mcp_ebird_integrity" =~ ^sha512-[A-Za-z0-9+/]+={0,2}$ ]] || exit 64
[[ "$mcp_pondlog_integrity" =~ ^sha512-[A-Za-z0-9+/]+={0,2}$ ]] || exit 64
id "$openclaw_user" >/dev/null
command -v getent >/dev/null
command -v flock >/dev/null
command -v jq >/dev/null
command -v npm >/dev/null
command -v openclaw >/dev/null
[[ "$sandbox_provisioner" == /* && -f "$sandbox_provisioner" &&
  ! -L "$sandbox_provisioner" ]] || {
  printf 'A validated sandbox provisioning script is required.\n' >&2
  exit 78
}
bash -n "$sandbox_provisioner"
if [[ -n "$runtime_installer" ]]; then
  [[ "$runtime_installer" == /* && -f "$runtime_installer" &&
    ! -L "$runtime_installer" && ${#runtime_installer_args[@]} -gt 0 ]] || exit 64
  bash -n "$runtime_installer"
elif (( ${#runtime_installer_args[@]} != 0 )); then
  exit 64
fi

# Inherit the installer's open file description rather than deadlocking on a
# second open. Standalone updates acquire exactly the same exclusive lock.
maintenance_lock=/etc/openclaw/maintenance.lock
[[ ! -L /etc/openclaw ]] || exit 78
install -d -o root -g root -m 0755 /etc/openclaw
if [[ ! -e "$maintenance_lock" && ! -L "$maintenance_lock" ]]; then
  (umask 022; set -o noclobber; : > "$maintenance_lock") || [[ -f "$maintenance_lock" ]]
fi
[[ -f "$maintenance_lock" && ! -L "$maintenance_lock" &&
  "$(stat -c '%u:%g:%a:%h' "$maintenance_lock")" == 0:0:644:1 ]] || {
  printf 'Unsafe OpenClaw maintenance lock.\n' >&2
  exit 78
}
if [[ "${OPENCLAW_MAINTENANCE_LOCK_HELD:-}" == 1 ]]; then
  [[ "$(readlink "/proc/$$/fd/8")" == "$maintenance_lock" ]] || exit 78
else
  exec 8<"$maintenance_lock"
fi
flock --exclusive --nonblock --conflict-exit-code 75 8 || {
  lock_status=$?
  if (( lock_status == 75 )); then
    printf 'OpenClaw maintenance or a protected runtime check is already running.\n' >&2
  fi
  exit "$lock_status"
}
export OPENCLAW_MAINTENANCE_LOCK_HELD=1
runtime_root=/var/lib/openclaw-runtime/update-recovery
install -d -o root -g root -m 0750 "$runtime_root"
systemctl cat openclaw-gateway.service >/dev/null
systemctl is-active --quiet openclaw-gateway.service || {
  printf 'The existing custom systemd Gateway must be active for this update path.\n' >&2
  exit 69
}

openclaw_home="$(getent passwd "$openclaw_user" | awk -F: 'NR == 1 { print $6 }')"
[[ "$openclaw_home" == /* && -d "$openclaw_home" ]] || {
  printf 'Could not resolve a safe home directory for the OpenClaw runtime user.\n' >&2
  exit 78
}
openclaw_state_dir="${openclaw_home}/.openclaw"

run_as_openclaw() {
  runuser -u "$openclaw_user" -- env \
    -u OPENCLAW_CONFIG_PATH \
    -u OPENCLAW_HOME \
    -u OPENCLAW_STATE_DIR \
    "HOME=${openclaw_home}" \
    "XDG_CACHE_HOME=${openclaw_home}/.cache" \
    "XDG_CONFIG_HOME=${openclaw_home}/.config" \
    "XDG_STATE_HOME=${openclaw_home}/.local/state" \
    "OPENCLAW_STATE_DIR=${openclaw_state_dir}" \
    OPENCLAW_SERVICE_REPAIR_POLICY=external \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    "$@"
}

assert_runtime_state_owned() {
  [[ ! -e "$openclaw_state_dir" ]] || [[ -z "$(find "$openclaw_state_dir" -xdev ! -user "$openclaw_user" -print -quit)" ]] || {
    printf 'OpenClaw state contains files not owned by the runtime user; refusing mutation.\n' >&2
    exit 78
  }
}

read_openclaw_version() {
  local output
  output="$(run_as_openclaw openclaw --version)"
  output="${output//$'\r'/}"
  [[ "$output" =~ ^OpenClaw[[:space:]]+([0-9]{4}\.[0-9]+\.[0-9]+)([[:space:]]+\([A-Za-z0-9._+-]+\))?$ ]] || {
    printf 'OpenClaw returned an unrecognized version string.\n' >&2
    return 1
  }
  printf '%s\n' "${BASH_REMATCH[1]}"
}

resolve_openclaw_package_root() {
  node - "$(command -v openclaw)" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
let current = path.dirname(fs.realpathSync(process.argv[2]));
for (;;) {
  const manifest = path.join(current, "package.json");
  if (fs.existsSync(manifest)) {
    const parsed = JSON.parse(fs.readFileSync(manifest, "utf8"));
    if (parsed.name === "openclaw") {
      process.stdout.write(current);
      process.exit(0);
    }
  }
  const parent = path.dirname(current);
  if (parent === current) process.exit(1);
  current = parent;
}
NODE
}
assert_runtime_state_owned

package_root_before="$(resolve_openclaw_package_root)"
package_parent="$(dirname "$package_root_before")"
global_prefix="$(npm prefix --global)"
global_prefix="$(realpath -e "$global_prefix")"
expected_package_root="${global_prefix}/lib/node_modules/openclaw"
[[ "$package_root_before" == "$expected_package_root" ]] || {
  printf 'OpenClaw package root does not match the configured npm global prefix.\n' >&2
  exit 78
}
openclaw_shim="$(command -v openclaw)"
shim_parent="$(dirname "$openclaw_shim")"
package_uid="$(stat -c %u "$package_root_before")"
package_gid="$(stat -c %g "$package_root_before")"
shim_uid="$(stat -c %u "$openclaw_shim")"
shim_gid="$(stat -c %g "$openclaw_shim")"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
artifact_dir="$(mktemp -d -p "$runtime_root" "${stamp}-XXXXXXXX")"
chown "$openclaw_user:$openclaw_user" "$artifact_dir"
chmod 0700 "$artifact_dir"
printf '%s\n' "$snapshot_evidence" > "$artifact_dir/snapshot-evidence.txt"
chmod 0600 "$artifact_dir/snapshot-evidence.txt"

run_as_openclaw timeout --signal=TERM --kill-after=5s 300s \
  openclaw backup verify "$verified_backup" \
  >"$artifact_dir/backup-verify.log" 2>&1 || {
    printf 'Backup verification failed; no package was changed. Evidence: %s\n' "$artifact_dir" >&2
    exit 78
  }

verify_registry_pin() {
  local package="$1" version="$2" integrity="$3" actual
  actual="$(timeout --signal=TERM --kill-after=5s 60s \
    npm view "${package}@${version}" dist.integrity --json | jq -er 'select(type == "string")')"
  [[ "$actual" == "$integrity" ]] || {
    printf 'Registry integrity mismatch for %s@%s.\n' "$package" "$version" >&2
    return 1
  }
}
verify_registry_pin openclaw "$target_version" "$openclaw_integrity"
verify_registry_pin @openclaw/diagnostics-otel \
  "$diagnostics_otel_version" "$diagnostics_otel_integrity"
verify_registry_pin @github/copilot "$copilot_version" "$copilot_integrity"
verify_registry_pin @pondlog/mcp-ebird "$mcp_ebird_version" "$mcp_ebird_integrity"
verify_registry_pin @pondlog/mcp-pondlog "$mcp_pondlog_version" "$mcp_pondlog_integrity"

run_as_openclaw timeout --signal=TERM --kill-after=5s 30s \
  openclaw update status --json >"$artifact_dir/update-status.json"
jq -e '
  (.update | type == "object") and
  (.update.installKind | IN("git", "package", "unknown")) and
  (.update.packageManager | IN("npm", "pnpm", "bun", "unknown")) and
  (.channel | type == "object") and
  (.channel.value | IN("stable", "extended-stable", "beta", "dev")) and
  (.channel.source | type == "string") and
  (.channel.label | type == "string") and
  (.availability | type == "object") and
  (.availability.available | type == "boolean")
' "$artifact_dir/update-status.json" >/dev/null || {
  printf 'OpenClaw update status returned an unrecognized JSON contract.\n' >&2
  exit 78
}

tasks_supported=false
if run_as_openclaw openclaw tasks list --help 2>&1 | grep -q -- '--status'; then
  tasks_supported=true
fi
if [[ "$tasks_supported" == true ]]; then
  deadline=$((SECONDS + drain_timeout))
  while :; do
    queued="$(run_as_openclaw timeout --signal=TERM --kill-after=5s 30s \
      openclaw tasks list --status queued --json)"
    running="$(run_as_openclaw timeout --signal=TERM --kill-after=5s 30s \
      openclaw tasks list --status running --json)"
    active_count="$(
      jq -s '
        if length == 2 and
           .[0].status == "queued" and .[1].status == "running" and
           .[0].runtime == null and .[1].runtime == null and
           all(.[];
             type == "object" and
             (.count | type) == "number" and .count >= 0 and
             (.tasks | type) == "array" and
             .count == (.tasks | length))
        then map(.tasks | length) | add
        else error("unrecognized task-list JSON")
        end
      ' <(printf '%s\n' "$queued") <(printf '%s\n' "$running")
    )"
    jq -nc --argjson active "$active_count" \
      '{supported:true,activeCount:$active}' > "$artifact_dir/tasks-inspection.json"
    (( active_count == 0 )) && break
    (( SECONDS < deadline )) || {
      printf 'Active work did not drain; no package was changed. Evidence: %s\n' "$artifact_dir" >&2
      exit 75
    }
    sleep 10
  done
else
  printf '%s\n' '{"supported":false}' > "$artifact_dir/tasks-inspection.json"
fi

gateway_stopped=false
update_succeeded=false
root_package_home=
package_ownership_captured=false
paused_timers=()
restore_timers() {
  if (( ${#paused_timers[@]} > 0 )); then
    systemctl start "${paused_timers[@]}"
  fi
}
restore_package_ownership() {
  local current_root
  [[ "$package_ownership_captured" == true ]] || return 0
  current_root="$(resolve_openclaw_package_root 2>/dev/null || true)"
  if [[ -n "$current_root" && -d "$current_root" ]]; then
    chown -R "$package_uid:$package_gid" "$current_root"
  fi
  if [[ -e "$openclaw_shim" || -L "$openclaw_shim" ]]; then
    chown -h "$shim_uid:$shim_gid" "$openclaw_shim"
  fi
}
leave_stopped_on_failure() {
  local code=$?
  trap - EXIT
  [[ -z "$root_package_home" ]] || rm -rf -- "$root_package_home"
  restore_package_ownership
  if [[ "$gateway_stopped" == true && "$update_succeeded" != true ]]; then
    if ! systemctl stop openclaw-gateway.service; then
      printf 'Failed to stop Gateway after unsuccessful validation; inspect it immediately.\n' >&2
      code=1
    fi
    printf 'Update validation failed; Gateway remains stopped. Recovery evidence: %s\n' \
      "$artifact_dir" >&2
  else
    if [[ "${OPENCLAW_MAINTENANCE_LOCK_HELD:-}" == 1 ]]; then
      flock --unlock 8
      exec 8<&-
      unset OPENCLAW_MAINTENANCE_LOCK_HELD
    fi
    if ! restore_timers; then
      printf 'Failed to restore the pre-maintenance OpenClaw timers.\n' >&2
      code=1
    fi
  fi
  exit "$code"
}
trap leave_stopped_on_failure EXIT

# Stop only our timers. Existing lockless service executions (from an older
# installation) must finish naturally before any runtime file is replaced.
for timer in openclaw-backup.timer openclaw-health.timer; do
  if systemctl is-active --quiet "$timer"; then
    paused_timers+=("$timer")
    systemctl stop "$timer"
  fi
done
deadline=$((SECONDS + drain_timeout))
for service in openclaw-backup.service openclaw-health.service; do
  while :; do
    state="$(systemctl show "$service" --property=ActiveState --value)"
    case "$state" in
      inactive|failed) break ;;
      active|activating|deactivating|reloading) ;;
      *) printf 'Unrecognized maintenance service state for %s.\n' "$service" >&2; exit 78 ;;
    esac
    (( SECONDS < deadline )) || {
      printf 'Existing backup/health work did not drain; runtime was not changed.\n' >&2
      exit 75
    }
    sleep 2
  done
done

bash "$sandbox_provisioner" \
  --source-commit "$sandbox_source_commit" \
  --archive-url "$sandbox_archive_url" \
  --archive-sha256 "$sandbox_archive_sha256" \
  --source-version "$target_version" \
  --browser-contract "$sandbox_browser_contract"

gateway_stopped=true
systemctl stop openclaw-gateway.service
[[ "$(systemctl show openclaw-gateway.service --property=ActiveState --value)" == inactive ]] || {
  printf 'Gateway did not stop; refusing package mutation.\n' >&2
  exit 78
}
package_ownership_captured=true

supported_updater_safe=false
used_npm_fallback=false
if run_as_openclaw test -w "$package_root_before" &&
  run_as_openclaw test -w "$package_parent" &&
  run_as_openclaw test -w "$shim_parent"; then
  supported_updater_safe=true
fi

if [[ "$supported_updater_safe" == true ]] &&
  run_as_openclaw openclaw update --help 2>&1 | grep -q -- '--tag' &&
  run_as_openclaw openclaw update --help 2>&1 | grep -q -- '--no-restart' &&
  run_as_openclaw openclaw update --help 2>&1 | grep -q -- '--json'; then
  run_as_openclaw timeout --signal=TERM --kill-after=30s 1900s \
    openclaw update --tag "$target_version" --no-restart --json \
    >"$artifact_dir/update.json" 2>"$artifact_dir/update.stderr"
  jq -e --arg version "$target_version" '
    (.status == "ok" and (.mode | IN("npm", "pnpm", "bun", "git")) and
      .after.version == $version and (.steps | type) == "array") or
    (.status == "skipped" and .reason == "already-current" and
      (.mode | IN("npm", "pnpm", "bun", "git", "unknown")) and
      (.steps | type) == "array")
  ' "$artifact_dir/update.json" >/dev/null || {
    printf 'OpenClaw update returned an unrecognized or unsuccessful result.\n' >&2
    exit 78
  }
else
  used_npm_fallback=true
  printf '%s\n' '{"mode":"bounded-npm-fallback","reason":"root-owned-package-root"}' \
    > "$artifact_dir/update.json"
  root_package_home="${artifact_dir}/root-package-home"
  install -d -o root -g root -m 0700 "$root_package_home"
  (
    umask 022
    timeout --signal=TERM --kill-after=30s 1900s \
      env HOME="$root_package_home" OPENCLAW_STATE_DIR="$root_package_home/.openclaw" \
      npm install --global --prefix "$global_prefix" --omit=dev "openclaw@${target_version}"
  ) >"$artifact_dir/npm-openclaw.log" 2>&1
  rm -rf -- "$root_package_home"
  root_package_home=
fi
package_root_after="$(resolve_openclaw_package_root)"
[[ "$package_root_after" == "$package_root_before" ]] || {
  printf 'Global package replacement moved the OpenClaw package root unexpectedly.\n' >&2
  exit 78
}
restore_package_ownership
package_ownership_captured=false

installed_version="$(read_openclaw_version)"
[[ "$installed_version" == "$target_version" ]] || {
  printf 'Installed CLI version is %s, expected %s.\n' "$installed_version" "$target_version" >&2
  exit 78
}

(
  umask 022
  timeout --signal=TERM --kill-after=30s 900s npm install --global --omit=dev \
    "@github/copilot@${copilot_version}"
) >"$artifact_dir/npm-copilot.log" 2>&1
(
  umask 022
  timeout --signal=TERM --kill-after=30s 900s npm install --global --omit=dev \
    --prefix /usr/local/lib/openclaw-mcp \
    "@pondlog/mcp-ebird@${mcp_ebird_version}" \
    "@pondlog/mcp-pondlog@${mcp_pondlog_version}"
) >"$artifact_dir/npm-mcp.log" 2>&1
run_as_openclaw timeout --signal=TERM --kill-after=30s 900s \
  openclaw plugins install \
  "npm:@openclaw/diagnostics-otel@${diagnostics_otel_version}" \
  --pin --force --accept-capabilities \
  >"$artifact_dir/diagnostics-plugin-install.log" \
  2>"$artifact_dir/diagnostics-plugin-install.stderr"

if [[ "$used_npm_fallback" == true ]]; then
  run_as_openclaw timeout --signal=TERM --kill-after=30s 1900s \
    openclaw doctor --fix \
    >"$artifact_dir/doctor-fix.log" 2>"$artifact_dir/doctor-fix.stderr"
  run_as_openclaw timeout --signal=TERM --kill-after=5s 120s \
    openclaw plugins list --json >"$artifact_dir/plugins.json"
  jq -e 'type == "object" and (.plugins | type) == "array"' \
    "$artifact_dir/plugins.json" >/dev/null
else
  run_as_openclaw timeout --signal=TERM --kill-after=30s 1900s \
    openclaw update repair --channel stable --json \
    >"$artifact_dir/update-repair.json" 2>"$artifact_dir/update-repair.stderr"
  jq -e '
    .status == "ok" and
    .mode == "finalize" and
    .channel == "stable" and
    .restart == false and
    (.phaseTimings | type) == "array" and
    .postUpdate.doctor.status == "ok" and
    (.postUpdate.plugins | type) == "object"
  ' "$artifact_dir/update-repair.json" >/dev/null || {
    printf 'OpenClaw update repair did not converge without capability widening.\n' >&2
    exit 78
  }
fi
run_as_openclaw timeout --signal=TERM --kill-after=5s 120s \
  openclaw plugins inspect diagnostics-otel --runtime --json \
  >"$artifact_dir/diagnostics-plugin-inspect.json"
jq -e \
  --arg version "$diagnostics_otel_version" \
  --arg integrity "$diagnostics_otel_integrity" '
    type == "object" and
    .plugin.id == "diagnostics-otel" and
    .plugin.version == $version and
    .plugin.enabled == true and
    .install.source == "npm" and
    .install.resolvedVersion == $version and
    .install.integrity == $integrity
  ' "$artifact_dir/diagnostics-plugin-inspect.json" >/dev/null || {
  printf 'Diagnostics plugin runtime metadata does not match the reviewed pin.\n' >&2
  exit 78
}
run_as_openclaw timeout --signal=TERM --kill-after=5s 120s \
  openclaw config validate --json >"$artifact_dir/config-validate.json"
jq -e '.valid == true' "$artifact_dir/config-validate.json" >/dev/null
set +e
run_as_openclaw timeout --signal=TERM --kill-after=5s 300s \
  openclaw doctor --lint --json >"$artifact_dir/doctor.json"
doctor_exit=$?
set -e
if (( doctor_exit != 0 && doctor_exit != 1 )); then
  printf 'OpenClaw Doctor lint could not complete.\n' >&2
  exit 78
fi
jq -e '
  type == "object" and
  (.findings | type) == "array" and
  ([.findings[] | select(.severity == "error")] | length) == 0
' "$artifact_dir/doctor.json" >/dev/null || {
  printf 'OpenClaw Doctor lint reported an error-severity finding.\n' >&2
  exit 78
}
assert_runtime_state_owned

global_node_modules="$(npm root --global)"
node - \
  "${global_node_modules}/@github/copilot/package.json" "$copilot_version" \
  "/usr/local/lib/openclaw-mcp/lib/node_modules/@pondlog/mcp-ebird/package.json" \
  "$mcp_ebird_version" \
  "/usr/local/lib/openclaw-mcp/lib/node_modules/@pondlog/mcp-pondlog/package.json" \
  "$mcp_pondlog_version" <<'NODE'
const [copilotPath, copilot, ebirdPath, ebird, pondlogPath, pondlog] =
  process.argv.slice(2);
const pins = [
  [copilotPath, copilot],
  [ebirdPath, ebird],
  [pondlogPath, pondlog],
];
for (const [path, expected] of pins) {
  if (require(path).version !== expected) process.exit(1);
}
NODE

if [[ -n "$runtime_installer" ]]; then
  OPENCLAW_INSTALL_PHASE=stopped bash "$runtime_installer" "${runtime_installer_args[@]}"
fi

systemctl restart openclaw-otel-collector.service
systemctl is-active --quiet openclaw-otel-collector.service
test -r /run/openclaw-otel/ready
systemctl start openclaw-gateway.service
timeout --signal=TERM --kill-after=5s 90s bash -c '
  until systemctl is-active --quiet openclaw-gateway.service &&
    curl --fail --silent --show-error http://127.0.0.1:18789/health >/dev/null; do
    sleep 3
  done
'
run_as_openclaw timeout --signal=TERM --kill-after=5s 120s \
  openclaw status --json >"$artifact_dir/running-status.json"
jq -e --arg version "$target_version" \
  '.gateway.reachable == true and .gateway.self.version == $version' \
  "$artifact_dir/running-status.json" >/dev/null || {
    printf 'Running Gateway did not prove exact version/readiness.\n' >&2
    exit 78
  }

update_succeeded=true
flock --unlock 8
exec 8<&-
unset OPENCLAW_MAINTENANCE_LOCK_HELD
if [[ -n "$runtime_installer" ]]; then
  systemctl start openclaw-backup.timer openclaw-health.timer
  paused_timers=()
else
  restore_timers
  paused_timers=()
fi
trap - EXIT
printf 'OpenClaw %s is running and ready. Evidence: %s\n' "$target_version" "$artifact_dir"
