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

# Temporary files are created with mktemp in the history directory (same filesystem, so mv is an
# atomic rename) and removed on exit. History files that are symlinks are never read or written.
temps=()
make_temp() { local t; t=$(mktemp "$history_dir/.tmp.XXXXXXXX") || return 1; temps+=("$t"); printf '%s' "$t"; }
trap 'rm -f -- "${temps[@]}"' EXIT

# Readable name plus a short hash, so URLs that sanitize to the same name never share a file.
history_file() {
  local safe hash
  safe=$(printf '%s' "$1" | sed -E 's#^https?://##; s#[^A-Za-z0-9.-]+#_#g; s#_+$##' | cut -c1-80)
  hash=$(printf '%s' "$1" | md5sum | cut -c1-8)
  printf '%s/%s-%s.tsv' "$history_dir" "$safe" "$hash"
}
