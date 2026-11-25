set -euo pipefail
filter=$1 vanilla=$2 google=$3 addon=$4
shift 4

write_spec() (
  local_file=$(mktemp .cell.XXXXXX)
  trap 'rm -f -- "$local_file"' EXIT
  printf '%s\n' "$1" > "$local_file"
  chmod 0644 "$local_file"
  mv -T -- "$local_file" cell.json
)

exec 9>> setup.lock
flock -x 9
previous=$(jq -c . cell.json)
selected=$(jq -c --arg vanilla "$vanilla" --arg google "$google" --arg addon "$addon" \
  -f "$filter" <<< "$previous")
[[ $previous != "$selected" ]] || exit 0

rollback() {
  status=$?
  trap - EXIT
  flock -x 9
  # Keep unrelated edits made by a concurrent invocation of the upstream helper.
  restored=$(jq -c --argjson previous "$previous" --argjson selected "$selected" '
    if [.data_dir, .gapps_dir] == [$selected.data_dir, $selected.gapps_dir] then
      del(.gapps_dir) + ($previous | {data_dir} + with_entries(select(.key == "gapps_dir")))
    else empty
    end
  ' cell.json)
  if [[ -n $restored ]]; then
    write_spec "$restored"
  fi
  exit "$status"
}

# The helper reads cell.json and takes setup.lock itself; unlock before calling it.
trap rollback EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
write_spec "$selected"
flock -u 9
"$@" 9>&-
trap - EXIT
