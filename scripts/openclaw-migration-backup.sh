#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 1 ]] || {
  printf 'Usage: %s <fresh-output-directory>\n' "$0" >&2
  exit 64
}
output_dir="$1"
state_dir="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
[[ -d "$state_dir" && ! -L "$state_dir" ]] || exit 66
[[ ! -e "$output_dir" ]] || {
  printf 'Output directory must not already exist: %s\n' "$output_dir" >&2
  exit 73
}
if systemctl is-active --quiet openclaw-gateway.service 2>/dev/null; then
  printf 'Stop the Gateway before creating a migration backup.\n' >&2
  exit 75
fi

state_dir="$(realpath -e "$state_dir")"
declare -a link_paths=()
declare -a link_targets=()

while IFS= read -r -d '' link_path; do
  target="$(readlink -- "$link_path")"
  case "$link_path -> $target" in
    "$state_dir"/plugin-skills/*" -> /usr/lib/node_modules/openclaw/"* | \
    "$state_dir"/plugin-skills/*" -> $state_dir/npm/projects/"* | \
    "$state_dir"/npm/projects/*"/node_modules/openclaw -> /usr/lib/node_modules/openclaw")
      ;;
    *)
      printf 'Refusing unrecognized absolute state symlink: %s\n' "$link_path" >&2
      exit 78
      ;;
  esac
  link_paths+=("$link_path")
  link_targets+=("$target")
done < <(find "$state_dir" -xdev -type l -lname '/*' -print0)

restore_links() {
  local code=$? index
  trap - EXIT
  for ((index = 0; index < ${#link_paths[@]}; index++)); do
    if [[ ! -e "${link_paths[$index]}" && ! -L "${link_paths[$index]}" ]]; then
      ln -s -- "${link_targets[$index]}" "${link_paths[$index]}"
    fi
  done
  exit "$code"
}
trap restore_links EXIT

for link_path in "${link_paths[@]}"; do
  rm -- "$link_path"
done

mkdir -m 0700 "$output_dir"
openclaw backup create --output "$output_dir" --verify --json
