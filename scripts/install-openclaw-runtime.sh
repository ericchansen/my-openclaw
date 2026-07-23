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
openclaw_version=2026.7.1
node_version=22.23.1
node_sha256=0294e8b915ab75f92c7513d2fcb830ae06e10684e6c603e99a87dbf8835389c1
copilot_version=1.0.71-3
mcp_ebird_version=0.1.5
mcp_pondlog_version=0.4.0
restart_gateway=true
asset_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) openclaw_user="$2"; shift 2 ;;
    --key-vault) key_vault_name="$2"; shift 2 ;;
    --storage-account) storage_account="$2"; shift 2 ;;
    --storage-container) storage_container="$2"; shift 2 ;;
    --openclaw-version) openclaw_version="$2"; shift 2 ;;
    --node-version) node_version="$2"; shift 2 ;;
    --node-sha256) node_sha256="$2"; shift 2 ;;
    --copilot-version) copilot_version="$2"; shift 2 ;;
    --mcp-ebird-version) mcp_ebird_version="$2"; shift 2 ;;
    --mcp-pondlog-version) mcp_pondlog_version="$2"; shift 2 ;;
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
id "$openclaw_user" >/dev/null
gateway_was_active=false
if systemctl is-active --quiet openclaw-gateway.service 2>/dev/null; then
  gateway_was_active=true
fi

required_assets=(
  openclaw-gateway.service
  openclaw-backup.service
  openclaw-backup.timer
  openclaw-health.service
  openclaw-health.timer
  openclaw-journald.conf
  openclaw-backup.sh
  openclaw-restore-verify.sh
  openclaw-health-check.sh
  openclaw-keyvault-resolver.py
  openclaw-gateway-launch.py
  openclaw-gog-launch.py
  openclaw-mcp-launch.py
)
for asset in "${required_assets[@]}"; do
  [[ -f "$asset_dir/$asset" ]] || {
    printf 'Missing runtime asset: %s\n' "$asset_dir/$asset" >&2
    exit 66
  }
done

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
  ca-certificates curl git gnupg jq procps python3 rsyslog sqlite3 tar util-linux xz-utils
)
docker_missing=false
command -v docker >/dev/null || docker_missing=true
apt-get install -y --no-install-recommends "${base_packages[@]}"

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

if [[ "$(node --version 2>/dev/null || true)" != "v${node_version}" ]]; then
  install_node
fi
npm install --global --omit=dev "openclaw@${openclaw_version}" "@github/copilot@${copilot_version}"
[[ "$(openclaw --version)" == *"$openclaw_version"* ]]
openclaw_executable="$(readlink -f "$(command -v openclaw)")"
[[ -f "$openclaw_executable" && -x "$openclaw_executable" ]]
install -d -o root -g root -m 0755 /usr/local/libexec
ln -sfn -- "$openclaw_executable" /usr/local/libexec/openclaw
chown -h root:root /usr/local/libexec/openclaw

install -d -o root -g root -m 0755 /usr/local/lib/openclaw-mcp
npm install --global --omit=dev --prefix /usr/local/lib/openclaw-mcp \
  "@pondlog/mcp-ebird@${mcp_ebird_version}" \
  "@pondlog/mcp-pondlog@${mcp_pondlog_version}"
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

install -d -o root -g root -m 0755 /etc/openclaw /usr/local/bin /usr/local/sbin
cat > /etc/openclaw/runtime.env <<EOF
OPENCLAW_KEY_VAULT=${key_vault_name}
OPENCLAW_BACKUP_ACCOUNT=${storage_account}
OPENCLAW_BACKUP_CONTAINER=${storage_container}
OPENCLAW_HEALTH_URL=http://127.0.0.1:18789/health
OPENCLAW_BACKUP_STATUS=/var/lib/openclaw-runtime/backup-status.json
OPENCLAW_BACKUP_MAX_AGE_SECONDS=129600
OPENCLAW_HEALTH_STATE_DIR=/var/lib/openclaw-runtime/health
OPENCLAW_CRON_RECENT_FAILURE_SECONDS=7200
OPENCLAW_CRON_FAILURE_THRESHOLD=2
EOF
chown root:root /etc/openclaw/runtime.env
chmod 0644 /etc/openclaw/runtime.env
touch /etc/openclaw/keyvault-allowlist
chown root:root /etc/openclaw/keyvault-allowlist
chmod 0644 /etc/openclaw/keyvault-allowlist

install -m 0755 "$asset_dir/openclaw-backup.sh" /usr/local/sbin/openclaw-backup
install -m 0755 "$asset_dir/openclaw-restore-verify.sh" /usr/local/sbin/openclaw-restore-verify
install -m 0755 "$asset_dir/openclaw-health-check.sh" /usr/local/sbin/openclaw-health-check
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
if [[ -n "$gog_executable" ]]; then
  ln -sfn -- /usr/local/bin/openclaw-gog-launch /usr/local/bin/gog
  chown -h root:root /usr/local/bin/gog
fi
for unit in openclaw-gateway.service openclaw-backup.service openclaw-health.service; do
  sed "s/__OPENCLAW_USER__/${openclaw_user}/g" "$asset_dir/$unit" \
    > "/etc/systemd/system/$unit"
done
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
install -d -o "$openclaw_user" -g "$openclaw_user" -m 0700 \
  /var/lib/openclaw-runtime/health
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
if [[ "$journald_changed" == true ]]; then
  systemctl restart systemd-journald.service
fi
systemctl enable docker.service rsyslog.service tailscaled.service
systemctl enable openclaw-backup.timer openclaw-health.timer
systemctl restart openclaw-backup.timer openclaw-health.timer
if [[ "$docker_changed" == true ]]; then
  if [[ "$docker_missing" == true ]]; then
    printf '%s\n' 'Docker logging defaults were installed before Docker first started.'
  else
    printf '%s\n' \
      'Docker logging defaults were merged and validated, but Docker was not restarted.' \
      'Activation requires an operator-controlled Docker daemon restart; afterward recreate only OpenClaw-owned containers.'
  fi
fi
if [[ "$gateway_was_active" == true ]]; then
  if ! runuser -u "$openclaw_user" -- env \
    "HOME=/home/${openclaw_user}" \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    openclaw config validate >/dev/null; then
    printf '%s\n' \
      'OpenClaw config validation failed; the already-active gateway was not restarted.' >&2
    exit 78
  fi
  systemctl enable openclaw-gateway.service
  if [[ "$restart_gateway" == true ]]; then
    systemctl restart openclaw-gateway.service
  else
    printf '%s\n' 'Gateway restart deferred by operator request.'
  fi
else
  printf '%s\n' \
    'The gateway was not active, so it was neither enabled nor started. Complete onboarding before enabling it.'
fi
printf 'OpenClaw runtime %s installed for %s.\n' "$openclaw_version" "$openclaw_user"
