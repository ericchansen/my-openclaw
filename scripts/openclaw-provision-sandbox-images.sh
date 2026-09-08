#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
  printf 'Run sandbox image provisioning as root.\n' >&2
  exit 77
fi
umask 077

source_commit=
archive_url=
archive_sha256=
source_version=
browser_contract=

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-commit) source_commit="$2"; shift 2 ;;
    --archive-url) archive_url="$2"; shift 2 ;;
    --archive-sha256) archive_sha256="$2"; shift 2 ;;
    --source-version) source_version="$2"; shift 2 ;;
    --browser-contract) browser_contract="$2"; shift 2 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done

[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || exit 64
[[ "$archive_url" == "https://codeload.github.com/openclaw/openclaw/tar.gz/${source_commit}" ]] || exit 64
[[ "$archive_sha256" =~ ^[0-9a-f]{64}$ ]] || exit 64
[[ "$source_version" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+$ ]] || exit 64
[[ "$browser_contract" =~ ^[A-Za-z0-9._-]+$ ]] || exit 64
command -v curl >/dev/null
command -v docker >/dev/null
command -v node >/dev/null
command -v sha256sum >/dev/null
command -v tar >/dev/null
docker info >/dev/null

state_root=/var/lib/openclaw-runtime/sandbox-source
install -d -o root -g root -m 0700 "$state_root"
work="$(mktemp -d -p "$state_root" source.XXXXXXXX)"
cleanup() {
  rm -rf -- "$work"
}
trap cleanup EXIT

archive="$work/source.tar.gz"
curl --fail --silent --show-error --location "$archive_url" --output "$archive"
chmod 0600 "$archive"
printf '%s  %s\n' "$archive_sha256" "$archive" | sha256sum --check -

source_directory="openclaw-${source_commit}"
tar -tzf "$archive" >"$work/archive-files.txt"
awk -v root="${source_directory}/" '
  index($0, root) != 1 { exit 1 }
  END { if (NR == 0) exit 1 }
' "$work/archive-files.txt" || {
  printf 'OpenClaw source archive has an unexpected root or unsafe member.\n' >&2
  exit 78
}
tar --extract --gzip --file "$archive" --directory "$work" --no-same-owner
source_root="$work/$source_directory"
[[ -d "$source_root" && ! -L "$source_root" ]]
[[ -x "$source_root/scripts/sandbox-setup.sh" ]]
[[ -x "$source_root/scripts/sandbox-browser-setup.sh" ]]
[[ -f "$source_root/scripts/docker/sandbox/Dockerfile" ]]
[[ -f "$source_root/scripts/docker/sandbox/Dockerfile.browser" ]]
node -e '
  const fs = require("node:fs");
  const [manifest, expected] = process.argv.slice(1);
  const parsed = JSON.parse(fs.readFileSync(manifest, "utf8"));
  if (parsed.name !== "openclaw" || parsed.version !== expected) process.exit(1);
' "$source_root/package.json" "$source_version"
grep -Fqx \
  "LABEL org.openclaw.sandbox-browser.contract=\"${browser_contract}\"" \
  "$source_root/scripts/docker/sandbox/Dockerfile.browser"

(
  cd "$source_root"
  ./scripts/sandbox-setup.sh
  ./scripts/sandbox-browser-setup.sh
)

docker image inspect openclaw-sandbox:bookworm-slim >/dev/null
actual_contract="$(
  docker image inspect --format \
    '{{ index .Config.Labels "org.openclaw.sandbox-browser.contract" }}' \
    openclaw-sandbox-browser:bookworm-slim
)"
[[ "$actual_contract" == "$browser_contract" ]] || {
  printf 'Sandbox browser image contract is %s, expected %s.\n' \
    "${actual_contract:-missing}" "$browser_contract" >&2
  exit 78
}
printf 'Verified OpenClaw %s sandbox images from commit %s.\n' \
  "$source_version" "$source_commit"
