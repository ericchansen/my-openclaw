#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
  printf 'Run this installer as root.\n' >&2
  exit 77
fi

openclaw_user=azureuser
key_vault_name=
storage_account=
storage_container=openclaw-backups
openclaw_version=
openclaw_integrity=
diagnostics_otel_version=
diagnostics_otel_integrity=
node_version=
node_sha256=
otel_version=
otel_url=
otel_sha256=
copilot_version=
copilot_integrity=
mcp_ebird_version=
mcp_ebird_integrity=
mcp_pondlog_version=
mcp_pondlog_integrity=
sandbox_source_commit=
sandbox_archive_url=
sandbox_archive_sha256=
sandbox_browser_contract=
verified_backup=
snapshot_evidence=
restart_gateway=true
asset_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
installer_path="$(readlink -f "${BASH_SOURCE[0]}")"
installer_args=("$@")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) openclaw_user="$2"; shift 2 ;;
    --key-vault) key_vault_name="$2"; shift 2 ;;
    --storage-account) storage_account="$2"; shift 2 ;;
    --storage-container) storage_container="$2"; shift 2 ;;
    --openclaw-version) openclaw_version="$2"; shift 2 ;;
    --openclaw-integrity) openclaw_integrity="$2"; shift 2 ;;
    --diagnostics-otel-version) diagnostics_otel_version="$2"; shift 2 ;;
    --diagnostics-otel-integrity) diagnostics_otel_integrity="$2"; shift 2 ;;
    --node-version) node_version="$2"; shift 2 ;;
    --node-sha256) node_sha256="$2"; shift 2 ;;
    --otel-version) otel_version="$2"; shift 2 ;;
    --otel-url) otel_url="$2"; shift 2 ;;
    --otel-sha256) otel_sha256="$2"; shift 2 ;;
    --copilot-version) copilot_version="$2"; shift 2 ;;
    --copilot-integrity) copilot_integrity="$2"; shift 2 ;;
    --mcp-ebird-version) mcp_ebird_version="$2"; shift 2 ;;
    --mcp-ebird-integrity) mcp_ebird_integrity="$2"; shift 2 ;;
    --mcp-pondlog-version) mcp_pondlog_version="$2"; shift 2 ;;
    --mcp-pondlog-integrity) mcp_pondlog_integrity="$2"; shift 2 ;;
    --sandbox-source-commit) sandbox_source_commit="$2"; shift 2 ;;
    --sandbox-archive-url) sandbox_archive_url="$2"; shift 2 ;;
    --sandbox-archive-sha256) sandbox_archive_sha256="$2"; shift 2 ;;
    --sandbox-browser-contract) sandbox_browser_contract="$2"; shift 2 ;;
    --verified-backup) verified_backup="$2"; shift 2 ;;
    --snapshot-evidence) snapshot_evidence="$2"; shift 2 ;;
    --asset-dir) asset_dir="$2"; shift 2 ;;
    --skip-gateway-restart) restart_gateway=false; shift ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done

[[ "$openclaw_user" =~ ^[a-z_][a-z0-9_-]*$ ]] || exit 64
[[ "$key_vault_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$ ]] || exit 64
[[ "$key_vault_name" != *--* ]] || exit 64
[[ "$storage_account" =~ ^[a-z0-9]{3,24}$ ]] || exit 64
[[ "$storage_container" =~ ^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$ ]] || exit 64
[[ "$openclaw_version" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+$ ]] || exit 64
[[ "$diagnostics_otel_version" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+$ ]] || exit 64
[[ "$node_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 64
[[ "$otel_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 64
[[ "$copilot_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 64
for value in \
  "$openclaw_integrity" "$diagnostics_otel_integrity" \
  "$node_sha256" "$otel_url" "$otel_sha256" "$copilot_integrity" \
  "$mcp_ebird_version" "$mcp_ebird_integrity" \
  "$mcp_pondlog_version" "$mcp_pondlog_integrity" \
  "$sandbox_source_commit" "$sandbox_archive_url" "$sandbox_archive_sha256" \
  "$sandbox_browser_contract"; do
  [[ -n "$value" ]] || exit 64
done
id "$openclaw_user" >/dev/null
openclaw_home="$(getent passwd "$openclaw_user" | awk -F: 'NR == 1 { print $6 }')"
[[ "$openclaw_home" == /* && -d "$openclaw_home" ]] || {
  printf 'Could not resolve a safe home directory for the OpenClaw runtime user.\n' >&2
  exit 78
}
openclaw_state_dir="${openclaw_home}/.openclaw"
openclaw_config="${openclaw_state_dir}/openclaw.json"
healthcheck_workspace="${openclaw_state_dir}/workspace-healthcheck"
for directory in "$openclaw_state_dir" "$healthcheck_workspace"; do
  [[ ! -L "$directory" && ( ! -e "$directory" || -d "$directory" ) ]] || {
    printf 'Refusing an unsafe healthcheck workspace or state directory.\n' >&2
    exit 78
  }
done

# Keep the inode stable: readers can open it, but cannot replace or truncate it.
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
inherited_maintenance_lock=false
if [[ "${OPENCLAW_MAINTENANCE_LOCK_HELD:-}" == 1 ]]; then
  [[ "$(readlink "/proc/$$/fd/8")" == "$maintenance_lock" ]] || exit 78
  inherited_maintenance_lock=true
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

install_stopped_runtime=false
if [[ "${OPENCLAW_INSTALL_PHASE:-}" == stopped ]]; then
  [[ "$inherited_maintenance_lock" == true ]] || exit 78
  [[ "$(systemctl show openclaw-gateway.service --property=ActiveState --value)" == inactive ]] || {
    printf 'Updater-owned runtime installation requires a stopped Gateway.\n' >&2
    exit 78
  }
  install_stopped_runtime=true
fi
gateway_was_active=false
if [[ "$install_stopped_runtime" == true ]] ||
  systemctl is-active --quiet openclaw-gateway.service 2>/dev/null; then
  gateway_was_active=true
elif systemctl cat openclaw-gateway.service >/dev/null 2>&1 &&
  [[ -f "$openclaw_config" ]]; then
  printf '%s\n' \
    'An existing Gateway unit is stopped. Refusing to treat this host as a fresh install.' \
    'Inspect update recovery artifacts and complete repair/validation offline.' >&2
  exit 78
fi

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

required_assets=(
  openclaw-gateway.service
  openclaw-backup.service
  openclaw-backup.timer
  openclaw-health.service
  openclaw-health.timer
  openclaw-journald.conf
  openclaw-otel-collector.service
  otelcol-openclaw.yaml
  openclaw-backup.sh
  openclaw-restore-verify.sh
  openclaw-health-check.sh
  openclaw-availability-check.py
  openclaw-keyvault-resolver.py
  openclaw-gateway-launch.py
  openclaw-gog-launch.py
  openclaw-mcp-launch.py
  openclaw-install-policy.py
  openclaw-provision-sandbox-images.sh
  openclaw-otel-ready
  openclaw-telemetry-access
  openclaw-update.sh
)
for asset in "${required_assets[@]}"; do
  [[ -f "$asset_dir/$asset" ]] || {
    printf 'Missing runtime asset: %s\n' "$asset_dir/$asset" >&2
    exit 66
  }
done

for asset in "$asset_dir"/*.sh; do
  bash -n "$asset"
done
python3 - "$asset_dir" <<'PY'
import pathlib
import sys

for path in pathlib.Path(sys.argv[1]).glob("*.py"):
    compile(path.read_bytes(), str(path), "exec")
PY

if [[ "$gateway_was_active" == true && "$install_stopped_runtime" != true ]]; then
  [[ "$restart_gateway" == true ]] || {
    printf 'Active-host updates cannot defer the updater-owned validated restart.\n' >&2
    exit 64
  }
  [[ "$(node --version 2>/dev/null || true)" == "v${node_version}" ]] || {
    printf 'Active-host updates require the already-tested Node %s.\n' "$node_version" >&2
    exit 78
  }
  # Run the staged updater before replacing any live helper, unit, or package.
  # It calls this installer back only after its own validated shutdown.
  exec bash "$asset_dir/openclaw-update.sh" \
    --target-version "$openclaw_version" \
    --verified-backup "$verified_backup" \
    --snapshot-evidence "$snapshot_evidence" \
    --user "$openclaw_user" \
    --openclaw-integrity "$openclaw_integrity" \
    --diagnostics-otel-version "$diagnostics_otel_version" \
    --diagnostics-otel-integrity "$diagnostics_otel_integrity" \
    --copilot-version "$copilot_version" \
    --copilot-integrity "$copilot_integrity" \
    --mcp-ebird-version "$mcp_ebird_version" \
    --mcp-ebird-integrity "$mcp_ebird_integrity" \
    --mcp-pondlog-version "$mcp_pondlog_version" \
    --mcp-pondlog-integrity "$mcp_pondlog_integrity" \
    --sandbox-source-commit "$sandbox_source_commit" \
    --sandbox-archive-url "$sandbox_archive_url" \
    --sandbox-archive-sha256 "$sandbox_archive_sha256" \
    --sandbox-browser-contract "$sandbox_browser_contract" \
    --sandbox-provisioner "$asset_dir/openclaw-provision-sandbox-images.sh" \
    --runtime-installer "$installer_path" -- "${installer_args[@]}"
fi

ensure_merged_lib64() {
  local source target
  local -a entries
  if [[ -d /lib64 && ! -L /lib64 ]]; then
    install -d -o root -g root -m 0755 /usr/lib64
    shopt -s dotglob nullglob
    entries=(/lib64/*)
    shopt -u dotglob nullglob
    for source in "${entries[@]}"; do
      target="/usr/lib64/$(basename "$source")"
      if [[ -e "$target" || -L "$target" ]]; then
        if [[ -f "$source" && -f "$target" ]] && cmp --silent "$source" "$target"; then
          rm -f -- "$source"
        else
          printf 'Refusing conflicting merged-/usr path: %s\n' "$target" >&2
          exit 78
        fi
      else
        mv -- "$source" "$target"
      fi
    done
    rmdir /lib64
    ln -s usr/lib64 /lib64
  fi
  if [[ -e /lib64 && ! -L /lib64 ]]; then
    printf '/lib64 is not compatible with merged-/usr.\n' >&2
    exit 78
  fi
}
ensure_merged_lib64

export DEBIAN_FRONTEND=noninteractive
# Package maintenance must never restart unrelated host services.
export NEEDRESTART_MODE=l
apt-get update
base_packages=(
  acl ca-certificates curl git gnupg jq procps python3 rsyslog sqlite3 tar util-linux xz-utils
)
docker_missing=false
command -v docker >/dev/null || docker_missing=true
apt-get install -y --no-install-recommends "${base_packages[@]}"

install_otel_collector() {
  local architecture archive extract_dir binary version_output
  architecture="$(dpkg --print-architecture)"
  [[ "$architecture" == arm64 ]] || {
    printf 'The pinned OpenTelemetry Collector artifact is for ARM64, not %s.\n' "$architecture" >&2
    exit 78
  }
  archive="$(mktemp -p /var/cache "otelcol-contrib-${otel_version}.tar.gz.XXXXXXXX")"
  extract_dir="$(mktemp -d -p /var/cache "otelcol-contrib-${otel_version}.XXXXXXXX")"
  trap 'rm -rf -- "$archive" "$extract_dir"' RETURN
  curl --fail --silent --show-error --location "$otel_url" --output "$archive"
  printf '%s  %s\n' "$otel_sha256" "$archive" | sha256sum --check -
  tar --extract --gzip --file "$archive" --directory "$extract_dir"
  binary="$extract_dir/otelcol-contrib"
  [[ -f "$binary" && -x "$binary" ]] || exit 78
  version_output="$("$binary" --version)"
  [[ "$version_output" == *"version ${otel_version}"* ]] || {
    printf 'OpenTelemetry Collector version validation failed.\n' >&2
    exit 78
  }
  install -d -o root -g root -m 0755 /usr/local/lib/openclaw-otel /usr/local/libexec
  install -o root -g root -m 0555 \
    "$binary" "/usr/local/lib/openclaw-otel/otelcol-contrib-${otel_version}"
  ln -sfn -- "/usr/local/lib/openclaw-otel/otelcol-contrib-${otel_version}" \
    /usr/local/libexec/otelcol-openclaw
  chown -h root:root /usr/local/libexec/otelcol-openclaw
  rm -rf -- "$archive" "$extract_dir"
  trap - RETURN
}

if [[ "$(/usr/local/libexec/otelcol-openclaw --version 2>/dev/null || true)" != *"version ${otel_version}"* ]]; then
  install_otel_collector
fi

install_node() {
  local architecture package url archive
  architecture="$(dpkg --print-architecture)"
  [[ "$architecture" == arm64 ]] || {
    printf 'The pinned Node checksum is for ARM64, not %s.\n' "$architecture" >&2
    exit 78
  }
  package="node-v${node_version}-linux-arm64.tar.xz"
  url="https://nodejs.org/dist/v${node_version}/${package}"
  archive="$(mktemp -p /var/cache "${package}.XXXXXXXX")"
  curl --fail --silent --show-error --location "$url" --output "$archive"
  printf '%s  %s\n' "$node_sha256" "$archive" | sha256sum --check -
  tar --extract --xz --file "$archive" --directory /usr/local --strip-components=1
  rm -f -- "$archive"
  [[ "$(node --version)" == "v${node_version}" ]]
}

if [[ "$gateway_was_active" == true && "$(node --version 2>/dev/null || true)" != "v${node_version}" ]]; then
  printf 'Active-host updates require the already-tested Node %s; found %s.\n' \
    "$node_version" "$(node --version 2>/dev/null || printf missing)" >&2
  exit 78
elif [[ "$(node --version 2>/dev/null || true)" != "v${node_version}" ]]; then
  install_node
fi
verify_registry_pin() {
  local package="$1" version="$2" integrity="$3" actual
  actual="$(timeout --signal=TERM --kill-after=5s 60s \
    npm view "${package}@${version}" dist.integrity --json | jq -er 'select(type == "string")')"
  [[ "$actual" == "$integrity" ]] || {
    printf 'Registry integrity mismatch for %s@%s.\n' "$package" "$version" >&2
    exit 78
  }
}
if [[ "$gateway_was_active" != true ]]; then
  verify_registry_pin openclaw "$openclaw_version" "$openclaw_integrity"
  verify_registry_pin @openclaw/diagnostics-otel \
    "$diagnostics_otel_version" "$diagnostics_otel_integrity"
  verify_registry_pin @github/copilot "$copilot_version" "$copilot_integrity"
  verify_registry_pin @pondlog/mcp-ebird "$mcp_ebird_version" "$mcp_ebird_integrity"
  verify_registry_pin @pondlog/mcp-pondlog "$mcp_pondlog_version" "$mcp_pondlog_integrity"
fi
if [[ "$gateway_was_active" != true ]]; then
  npm install --global --omit=dev "openclaw@${openclaw_version}" "@github/copilot@${copilot_version}"
fi
installed_openclaw_output="$(openclaw --version)"
installed_openclaw_output="${installed_openclaw_output//$'\r'/}"
[[ "$installed_openclaw_output" =~ ^OpenClaw[[:space:]]+([0-9]{4}\.[0-9]+\.[0-9]+)([[:space:]]+\([A-Za-z0-9._+-]+\))?$ ]] || {
  printf 'OpenClaw returned an unrecognized version string.\n' >&2
  exit 78
}
installed_openclaw_version="${BASH_REMATCH[1]}"
[[ "$gateway_was_active" == true || "$installed_openclaw_version" == "$openclaw_version" ]]
openclaw_executable="$(readlink -f "$(command -v openclaw)")"
[[ -f "$openclaw_executable" && -x "$openclaw_executable" ]]
install -d -o root -g root -m 0755 /usr/local/libexec
ln -sfn -- "$openclaw_executable" /usr/local/libexec/openclaw
chown -h root:root /usr/local/libexec/openclaw

install -d -o root -g root -m 0755 /usr/local/lib/openclaw-mcp
if [[ "$gateway_was_active" != true ]]; then
  npm install --global --omit=dev --prefix /usr/local/lib/openclaw-mcp \
    "@pondlog/mcp-ebird@${mcp_ebird_version}" \
    "@pondlog/mcp-pondlog@${mcp_pondlog_version}"
fi
[[ -x /usr/local/lib/openclaw-mcp/bin/pondlog-mcp-ebird ]]
[[ -x /usr/local/lib/openclaw-mcp/bin/pondlog-mcp-pondlog ]]
node -e '
  const [path, expected] = process.argv.slice(1);
  if (require(path).version !== expected) process.exit(1);
' \
  /usr/local/lib/openclaw-mcp/lib/node_modules/@pondlog/mcp-ebird/package.json \
  "$mcp_ebird_version"
node -e '
  const [path, expected] = process.argv.slice(1);
  if (require(path).version !== expected) process.exit(1);
' \
  /usr/local/lib/openclaw-mcp/lib/node_modules/@pondlog/mcp-pondlog/package.json \
  "$mcp_pondlog_version"

gog_executable=
if [[ -x /usr/local/libexec/gog ]] && \
  [[ "$(readlink -f /usr/local/bin/gog 2>/dev/null || true)" == /usr/local/bin/openclaw-gog-launch ]]; then
  gog_executable=/usr/local/libexec/gog
elif command -v gog >/dev/null; then
  gog_executable="$(readlink -f "$(command -v gog)")"
  [[ -f "$gog_executable" && -x "$gog_executable" ]]
  if [[ "$gog_executable" == /usr/local/bin/gog ]]; then
    mv -f -- /usr/local/bin/gog /usr/local/libexec/gog
  else
    ln -sfn -- "$gog_executable" /usr/local/libexec/gog
    chown -h root:root /usr/local/libexec/gog
  fi
  gog_executable=/usr/local/libexec/gog
fi

install_microsoft_repo() {
  local key=/usr/share/keyrings/microsoft-prod.gpg
  curl --fail --silent --show-error --location \
    https://packages.microsoft.com/keys/microsoft.asc |
    gpg --dearmor --yes --output "$key"
  chmod 0644 "$key"
  printf '%s\n' \
    "deb [arch=arm64 signed-by=$key] https://packages.microsoft.com/repos/azure-cli/ noble main" \
    > /etc/apt/sources.list.d/azure-cli.list
}
if ! command -v az >/dev/null; then
  install_microsoft_repo
  apt-get update
  apt-get install -y --no-install-recommends azure-cli
fi

install_tailscale_repo() {
  local key=/usr/share/keyrings/tailscale-archive-keyring.gpg
  curl --fail --silent --show-error --location \
    https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg \
    --output "$key"
  chmod 0644 "$key"
  printf '%s\n' \
    "deb [signed-by=$key] https://pkgs.tailscale.com/stable/ubuntu noble main" \
    > /etc/apt/sources.list.d/tailscale.list
}
if ! command -v tailscale >/dev/null; then
  install_tailscale_repo
  apt-get update
  apt-get install -y --no-install-recommends tailscale
fi

getent passwd openclaw-otel >/dev/null ||
  useradd --system --user-group --home-dir /var/lib/openclaw-otel \
    --shell /usr/sbin/nologin openclaw-otel
IFS=: read -r otel_account _ otel_uid otel_gid _ otel_home otel_shell \
  < <(getent passwd openclaw-otel)
[[ "$otel_account" == openclaw-otel &&
  "$otel_home" == /var/lib/openclaw-otel &&
  "$otel_shell" == /usr/sbin/nologin &&
  "$otel_uid" -lt 1000 ]]
[[ "$(getent group openclaw-otel | cut -d: -f3)" == "$otel_gid" ]]
install -d -o root -g root -m 0755 /etc/openclaw /usr/local/bin /usr/local/sbin
cat > /etc/openclaw/runtime.env <<EOF
OPENCLAW_KEY_VAULT=${key_vault_name}
OPENCLAW_BACKUP_ACCOUNT=${storage_account}
OPENCLAW_BACKUP_CONTAINER=${storage_container}
OPENCLAW_HEALTH_URL=http://127.0.0.1:18789/health
OPENCLAW_BACKUP_STATUS=/var/lib/openclaw-runtime/backup-status.json
OPENCLAW_BACKUP_MAX_AGE_SECONDS=129600
OPENCLAW_HEALTH_STATE_DIR=/var/lib/openclaw-runtime/health
OPENCLAW_AUTOMATION_RECENT_FAILURE_SECONDS=7200
OPENCLAW_AUTOMATION_FAILURE_THRESHOLD=2
EOF
chown root:root /etc/openclaw/runtime.env
chmod 0644 /etc/openclaw/runtime.env
touch /etc/openclaw/keyvault-allowlist
chown root:root /etc/openclaw/keyvault-allowlist
chmod 0644 /etc/openclaw/keyvault-allowlist

install -m 0755 "$asset_dir/openclaw-backup.sh" /usr/local/sbin/openclaw-backup
install -m 0755 "$asset_dir/openclaw-restore-verify.sh" /usr/local/sbin/openclaw-restore-verify
install -m 0755 "$asset_dir/openclaw-health-check.sh" /usr/local/sbin/openclaw-health-check
install -o root -g root -m 0555 \
  "$asset_dir/openclaw-availability-check.py" \
  /usr/local/libexec/openclaw-availability-check
install -m 0755 "$asset_dir/openclaw-update.sh" /usr/local/sbin/openclaw-update
install -o "$openclaw_user" -g "$openclaw_user" -m 0555 \
  "$asset_dir/openclaw-keyvault-resolver.py" \
  /usr/local/bin/openclaw-keyvault-resolver
install -o root -g root -m 0555 \
  "$asset_dir/openclaw-gateway-launch.py" \
  /usr/local/bin/openclaw-gateway-launch
install -o root -g root -m 0555 \
  "$asset_dir/openclaw-gog-launch.py" \
  /usr/local/bin/openclaw-gog-launch
install -o root -g root -m 0555 \
  "$asset_dir/openclaw-mcp-launch.py" \
  /usr/local/bin/openclaw-mcp-launch
install -o root -g root -m 0555 \
  "$asset_dir/openclaw-install-policy.py" \
  /usr/local/bin/openclaw-install-policy
install -o root -g root -m 0555 \
  "$asset_dir/openclaw-provision-sandbox-images.sh" \
  /usr/local/sbin/openclaw-provision-sandbox-images
install -o root -g root -m 0555 \
  "$asset_dir/openclaw-otel-ready" \
  /usr/local/sbin/openclaw-otel-ready
install -o root -g root -m 0555 \
  "$asset_dir/openclaw-telemetry-access" \
  /usr/local/sbin/openclaw-telemetry-access
if [[ "$gateway_was_active" != true && -f "$openclaw_config" ]]; then
  [[ -z "$(find "$openclaw_state_dir" -xdev ! -user "$openclaw_user" -print -quit)" ]] || {
    printf 'OpenClaw state contains files not owned by the runtime user; refusing plugin install.\n' >&2
    exit 78
  }
  run_as_openclaw timeout --signal=TERM --kill-after=30s 900s \
    openclaw plugins install \
    "npm:@openclaw/diagnostics-otel@${diagnostics_otel_version}" \
    --pin --force --accept-capabilities
  diagnostics_metadata="$(
    run_as_openclaw timeout --signal=TERM --kill-after=5s 120s \
      openclaw plugins inspect diagnostics-otel --runtime --json
  )"
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
    ' <<<"$diagnostics_metadata" >/dev/null || {
    printf 'Diagnostics plugin runtime metadata does not match the reviewed pin.\n' >&2
    exit 78
  }
elif [[ "$gateway_was_active" != true ]]; then
  printf '%s\n' \
    'Diagnostics plugin installation is deferred until onboarding creates the runtime config.' \
    'Install the reviewed pin before enabling the Gateway; do not create placeholder config.'
fi
if [[ -n "$gog_executable" ]]; then
  ln -sfn -- /usr/local/bin/openclaw-gog-launch /usr/local/bin/gog
  chown -h root:root /usr/local/bin/gog
fi
for unit in openclaw-gateway.service openclaw-backup.service openclaw-health.service; do
  sed "s/__OPENCLAW_USER__/${openclaw_user}/g" "$asset_dir/$unit" \
    > "/etc/systemd/system/$unit"
done
install -o root -g openclaw-otel -m 0640 \
  "$asset_dir/otelcol-openclaw.yaml" \
  /etc/openclaw/otelcol-openclaw.yaml
install -o root -g root -m 0644 \
  "$asset_dir/openclaw-otel-collector.service" \
  /etc/systemd/system/openclaw-otel-collector.service
install -m 0644 "$asset_dir/openclaw-backup.timer" /etc/systemd/system/openclaw-backup.timer
install -m 0644 "$asset_dir/openclaw-health.timer" /etc/systemd/system/openclaw-health.timer
journald_changed=false
install -d -o root -g root -m 0755 /etc/systemd/journald.conf.d
if ! cmp --silent \
  "$asset_dir/openclaw-journald.conf" \
  /etc/systemd/journald.conf.d/60-openclaw-retention.conf 2>/dev/null; then
  install -o root -g root -m 0644 \
    "$asset_dir/openclaw-journald.conf" \
    /etc/systemd/journald.conf.d/60-openclaw-retention.conf
  journald_changed=true
fi
chmod 0644 /etc/systemd/system/openclaw-*.service
install -d -o "$openclaw_user" -g "$openclaw_user" -m 0750 \
  /var/log/openclaw /var/lib/openclaw-runtime
install -d -o openclaw-otel -g openclaw-otel -m 0750 /var/lib/openclaw-otel
/usr/local/sbin/openclaw-telemetry-access
install -d -o "$openclaw_user" -g "$openclaw_user" -m 0700 \
  /var/lib/openclaw-runtime/health
if [[ ! -e "$openclaw_state_dir" ]]; then
  install -d -o "$openclaw_user" -g "$openclaw_user" -m 0700 "$openclaw_state_dir"
fi
install -d -o "$openclaw_user" -g "$openclaw_user" -m 0700 "$healthcheck_workspace"
install -d -o root -g systemd-journal -m 2755 /var/log/journal
systemd-tmpfiles --create --prefix /var/log/journal
touch /var/log/openclaw/openclaw.log
chown "$openclaw_user:$openclaw_user" /var/log/openclaw/openclaw.log
chmod 0600 /var/log/openclaw/openclaw.log

docker_changed="$(python3 - <<'PY'
import json
import os
import pathlib

path = pathlib.Path("/etc/docker/daemon.json")
data = json.loads(path.read_text()) if path.exists() else {}
data.setdefault("log-driver", "local")
if data["log-driver"] in {"local", "json-file"}:
    options = data.setdefault("log-opts", {})
    options.setdefault("max-size", "10m")
    options.setdefault("max-file", "3")
rendered = json.dumps(data, indent=2, sort_keys=True) + "\n"
if not path.exists() or path.read_text() != rendered:
    path.parent.mkdir(parents=True, exist_ok=True)
    candidate = path.with_name("daemon.json.openclaw-new")
    candidate.write_text(rendered)
    os.chmod(candidate, 0o644)
    candidate.replace(path)
    json.loads(path.read_text())
    print("true")
else:
    print("false")
PY
)"
if [[ "$docker_missing" == true ]]; then
  apt-get install -y --no-install-recommends docker.io
fi

systemctl daemon-reload
if [[ "$docker_missing" == true ]]; then
  systemctl enable --now docker.service
fi
getent group docker >/dev/null || {
  printf 'Docker installation did not create its expected access group.\n' >&2
  exit 78
}
usermod -aG docker "$openclaw_user"
systemctl is-active --quiet docker.service || {
  printf 'Docker must be active before sandbox images can be provisioned.\n' >&2
  exit 78
}
runuser -u "$openclaw_user" -- docker info >/dev/null || {
  printf 'The OpenClaw runtime user cannot access the Docker sandbox backend.\n' >&2
  exit 78
}
if [[ "$journald_changed" == true ]]; then
  systemctl restart systemd-journald.service
fi
systemctl enable docker.service rsyslog.service
systemctl enable --now tailscaled.service
systemctl enable openclaw-otel-collector.service
if [[ "$install_stopped_runtime" != true ]]; then
  if systemctl is-active --quiet openclaw-otel-collector.service; then
    systemctl restart openclaw-otel-collector.service
  else
    systemctl start openclaw-otel-collector.service
  fi
  systemctl is-active --quiet openclaw-otel-collector.service
  test -r /run/openclaw-otel/ready
fi
if [[ "$docker_changed" == true ]]; then
  if [[ "$docker_missing" == true ]]; then
    printf '%s\n' 'Docker logging defaults were installed before Docker first started.'
  else
    printf '%s\n' \
      'Docker logging defaults were merged and validated, but Docker was not restarted.' \
      'Activation requires an operator-controlled Docker daemon restart; afterward recreate only OpenClaw-owned containers.'
  fi
fi
if [[ "$gateway_was_active" != true ]]; then
  /usr/local/sbin/openclaw-provision-sandbox-images \
    --source-commit "$sandbox_source_commit" \
    --archive-url "$sandbox_archive_url" \
    --archive-sha256 "$sandbox_archive_sha256" \
    --source-version "$openclaw_version" \
    --browser-contract "$sandbox_browser_contract"
fi
if [[ "$install_stopped_runtime" == true ]]; then
  systemctl enable openclaw-gateway.service
else
  printf '%s\n' \
    'The gateway was not active, so it was neither enabled nor started. Complete onboarding before enabling it.'
fi
systemctl enable openclaw-backup.timer openclaw-health.timer
if [[ "$install_stopped_runtime" != true ]]; then
  flock --unlock 8
  exec 8<&-
  unset OPENCLAW_MAINTENANCE_LOCK_HELD
  systemctl restart openclaw-backup.timer openclaw-health.timer
fi
printf 'OpenClaw runtime %s installed for %s.\n' "$openclaw_version" "$openclaw_user"
