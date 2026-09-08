#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || {
  printf 'Permission contract test must run as root.\n' >&2
  exit 77
}
getent passwd nobody >/dev/null

scratch="/var/cache/openclaw-permission-test.$$"
runtime="${scratch}/run/openclaw-otel"
marker="${runtime}/ready"
trap 'rm -rf -- "$scratch"' EXIT

install -d -o root -g root -m 0755 "$scratch"
install -d -o root -g root -m 0755 "$runtime"
: > "$marker"
chmod 0444 "$marker"

runuser -u nobody -- test -x "$runtime"
runuser -u nobody -- test -r "$marker"
if runuser -u nobody -- test -w "$marker"; then
  printf 'Unprivileged Gateway fixture can write the readiness marker.\n' >&2
  exit 78
fi
if runuser -u nobody -- touch "${runtime}/gateway-write" 2>/dev/null; then
  printf 'Unprivileged Gateway fixture can write the collector runtime directory.\n' >&2
  exit 78
fi

[[ "$(stat -c '%a' "$runtime")" == 755 ]]
[[ "$(stat -c '%a' "$marker")" == 444 ]]
printf 'Telemetry readiness permission contract passed.\n'
