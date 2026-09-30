#!/usr/bin/env bash
# Usage: detail.sh URL SLOW_MS
# Prints the last 10 checks for URL, newest first:  check, epoch, up, status, http code, ms
# then one uptime series per window, oldest bucket first ("" = no checks in that bucket):
#   series, hour|day|week|month, uptime pct...
#   slow, hour|day|week|month, pct of checks that were up but slower than SLOW_MS...
# Windows match `windows` in Uptime.qml: 18 x 10 min, 24 x 1 h, 28 x 6 h, 30 x 1 day.
source "$(dirname "$0")/history.sh"
enter_history_dir || exit 0
history=$(history_file "$1")
[[ -f $history ]] || exit 0
read_nofollow "$history" 2>/dev/null | tail -n "$max_records" | awk -F'\t' -v now="$(date +%s)" -v slowms="${2:-0}" '
  BEGIN {
    key[1] = "day";   size[1] = 3600;  count[1] = 24
    key[2] = "week";  size[2] = 21600; count[2] = 28
    key[3] = "month"; size[3] = 86400; count[3] = 30
    key[4] = "hour";  size[4] = 600;   count[4] = 18
  }
  {
    n++; last[n % 10] = $0
    for (w = 1; w <= 4; w++) {
      i = int((now - $1) / size[w])
      if (i < count[w]) { total[w, i]++; up[w, i] += $2; if ($2 && $5 != "" && slowms > 0 && $5 + 0 > slowms + 0) slow[w, i]++ }
    }
  }
  END {
    for (k = 0; k < 10 && k < n; k++) {
      split(last[(n - k) % 10], f, "\t")
      print "check\t" f[1] "\t" f[2] "\t" f[3] "\t" f[4] "\t" f[5]
    }
    for (w = 1; w <= 4; w++) {
      line = "series\t" key[w]
      for (i = count[w] - 1; i >= 0; i--)
        line = line "\t" (total[w, i] ? sprintf("%.2f", 100 * up[w, i] / total[w, i]) : "")
      print line
      line = "slow\t" key[w]
      for (i = count[w] - 1; i >= 0; i--)
        line = line "\t" (total[w, i] ? sprintf("%.2f", 100 * slow[w, i] / total[w, i]) : "")
      print line
    }
  }'
