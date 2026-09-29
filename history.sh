# Sourced by check.sh and detail.sh. One history file per URL, one line per check:
# epoch, up (0/1: 2xx with valid SSL), status, http code, ms
history_dir=${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/http-uptime

# Resource bounds (Uptime.qml mirrors the target and URL limits).
# 100k records hold 30 days of history at the 30 s minimum interval.
max_records=100000
max_parallel=6
max_targets=50
max_url_length=2048

# Readable name plus a short hash, so URLs that sanitize to the same name never share a file.
history_file() {
  local safe hash
  safe=$(printf '%s' "$1" | sed -E 's#^https?://##; s#[^A-Za-z0-9.-]+#_#g; s#_+$##' | cut -c1-80)
  hash=$(printf '%s' "$1" | md5sum | cut -c1-8)
  printf '%s/%s-%s.tsv' "$history_dir" "$safe" "$hash"
}
