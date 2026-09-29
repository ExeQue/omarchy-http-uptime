# Sourced by check.sh and detail.sh. One history file per URL, one line per check:
# epoch, up (0/1: 2xx with valid SSL), status, http code, ms
history_dir=${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/http-uptime

# Resource bounds (Uptime.qml mirrors the target and URL limits).
# 100k records hold 30 days of history at the 30 s minimum interval.
max_records=100000
max_parallel=6
max_targets=50
max_url_length=2048
max_headers=10
max_header_value=4096
# A locked keyring can wait for an unlock prompt, so every keyring call is bounded.
keyring_lookup_timeout=3
keyring_write_timeout=30

# File safety. Scripts that touch history call enter_history_dir first: it refuses a symlinked or
# foreign directory, then makes it the working directory, so every later path is relative to that
# verified directory (in effect a held directory handle) and a swapped pathname can't redirect it.
# Inside it, history files are opened with O_NOFOLLOW (dd iflag/oflag=nofollow), replaced by
# rename (mv -T, which replaces a symlink rather than following it) and touched with touch -h.
# Temporary files come from mktemp (O_EXCL, unpredictable names) and are removed on exit.
enter_history_dir() {
  mkdir -p -- "$history_dir" || return 1
  [[ ! -L $history_dir ]] || { echo "refusing symlinked history directory: $history_dir" >&2; return 1; }
  cd -P -- "$history_dir" || return 1
  # The directory we are in must be the one at that path (not a symlink swapped in) and ours.
  [[ $(stat -c %d:%i .) == "$(stat -c %d:%i -- "$history_dir")" && -O . ]] \
    || { echo "refusing unexpected history directory: $history_dir" >&2; return 1; }
  chmod 700 .
}

temps=()
make_temp() { local t; t=$(mktemp ./.tmp.XXXXXXXX) || return 1; temps+=("$t"); printf '%s' "$t"; }
trap 'rm -f -- "${temps[@]}"' EXIT

read_nofollow() { dd if="$1" iflag=nofollow status=none; }
append_nofollow() { dd of="$1" oflag=append,nofollow conv=notrunc status=none; }

# History file name (relative to the history directory): a readable form of the URL plus a short
# hash, so URLs that sanitize to the same name never share a file.
history_file() {
  local safe hash
  safe=$(printf '%s' "$1" | sed -E 's#^https?://##; s#[^A-Za-z0-9.-]+#_#g; s#_+$##' | cut -c1-80)
  hash=$(printf '%s' "$1" | md5sum | cut -c1-8)
  printf '%s-%s.tsv' "$safe" "$hash"
}
