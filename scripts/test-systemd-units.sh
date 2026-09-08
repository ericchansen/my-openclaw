#!/usr/bin/env bash
set -Eeuo pipefail

config_dir="${1:-}"
[[ -d "$config_dir" ]] || exit 64
command -v systemd-analyze >/dev/null || {
  printf 'systemd-analyze is required for unit validation.\n' >&2
  exit 69
}

scratch="${HOME}/.cache/openclaw-systemd-test.$$"
trap 'rm -rf -- "$scratch"' EXIT
install -d -m 0700 "$scratch"

units=()
shopt -s nullglob
for source in "$config_dir"/*.service "$config_dir"/*.timer; do
  target="${scratch}/$(basename "$source")"
  tr -d '\r' < "$source" |
    sed -E 's#^(Exec(Start|StartPre|StartPost|Stop|StopPost|Reload)=)([+!:@-]*)(/[^ ]+)#\1\3/usr/bin/true#' \
      > "$target"
  chmod 0644 "$target"
  units+=("$target")
done
shopt -u nullglob
(( ${#units[@]} > 0 ))

systemd-analyze verify "${units[@]}"
printf 'All %s systemd units passed verification.\n' "${#units[@]}"
