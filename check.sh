#!/usr/bin/env bash
# Usage: [UPTIME_KEEP=$'url\tslow-ms\n...'] check.sh URL...
# Prints one tab-separated line per URL: url, status, http code, response ms, cert days left, detail.
# status: ok | down | ssl. curl verifies the chain and hostname; openssl only reads the expiry date.
# Each result is appended to the URL's history file (see history.sh). Afterwards one line per URL in
# UPTIME_KEEP (or the arguments) gives uptime and when the current outage / slow streak began:
#   stats, url, 24h %, 7d %, 30d %, down-since epoch, slow-since epoch (empty when not ongoing)
# A check is slow when it is up and slower than the URL's slow-ms from UPTIME_KEEP.
# History files for URLs missing from UPTIME_KEEP (removed or renamed entries) are deleted.

source "$(dirname "$0")/history.sh"
mkdir -p "$history_dir"

check() {
  local url=$1 code secs ms rc days="" detail="" status host port end
  read -r code secs detail < <(curl -s -L -o /dev/null -w '%{http_code} %{time_total} %{exitcode} %{errormsg}' --max-time 10 "$url")
  ms=$(awk -v s="$secs" 'BEGIN { printf "%d", s * 1000 }')
  rc=${detail%% *}; detail=${detail#"$rc"}; detail=${detail# }

  if [[ $url == https://* ]]; then
    host=${url#https://}; host=${host%%/*}; port=443
    [[ $host == *:* ]] && port=${host##*:} && host=${host%%:*}
    end=$(timeout 10 openssl s_client -servername "$host" -connect "$host:$port" </dev/null 2>/dev/null \
      | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    [[ -n $end ]] && days=$(( ($(date -d "$end" +%s) - $(date +%s)) / 86400 ))
  fi

  case $rc in
    0) [[ $code == 2* ]] && status=ok || { status=down; detail="HTTP $code"; } ;;
    35|51|53|54|58|59|60|64|66|77|80|82|83|90|91)
      status=ssl
      # Short labels for the common certificate failures; anything else keeps curl's message.
      case ${detail,,} in
        *expired*) detail="Certificate expired" ;;
        *"subject name"*|*"does not match"*) detail="Certificate hostname mismatch" ;;
        *self-signed*|*"self signed"*) detail="Self-signed certificate" ;;
        *"local issuer"*|*"unknown ca"*) detail="Untrusted certificate issuer" ;;
        *revoked*) detail="Certificate revoked" ;;
      esac ;;
    *) status=down ;;
  esac

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$url" "$status" "$code" "$ms" "$days" "$detail"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$([[ $status == ok ]] && echo 1 || echo 0)" "$status" "$code" "$ms" >> "$(history_file "$url")"
}

for url in "$@"; do check "$url" & done
wait

declare -A kept slow
if [[ -n ${UPTIME_KEEP:-} ]]; then
  urls=()
  while IFS=$'\t' read -r url ms; do
    urls+=("$url"); slow[$url]=$ms; kept[$(history_file "$url")]=1
  done <<< "$UPTIME_KEEP"
  for file in "$history_dir"/*.tsv; do
    [[ -e $file && -z ${kept[$file]:-} ]] && rm -f "$file"
  done
else
  urls=("$@")
fi

# ponytail: stats rescan each URL's 30-day history every run; fine for a handful of URLs,
# pre-aggregate per hour if files grow past a few MB.
for url in "${urls[@]}"; do
  file=$(history_file "$url")
  [[ -f $file ]] || continue
  awk -F'\t' -v url="$url" -v slow="${slow[$url]:-}" -v now="$(date +%s)" -v out="$file.tmp" '
    BEGIN { span[1] = 86400; span[2] = 7 * 86400; span[3] = 30 * 86400; printf "" > out }
    now - $1 > 30 * 86400 { pruned = 1; next }
    { print > out
      for (w = 1; w <= 3; w++) if (now - $1 <= span[w]) { total[w]++; up[w] += $2 }
      if ($2) since = ""; else if (since == "") since = $1
      if ($2 && slow != "" && $5 != "" && $5 + 0 > slow + 0) { if (slowSince == "") slowSince = $1 } else slowSince = "" }
    END {
      line = "stats\t" url
      for (w = 1; w <= 3; w++) line = line "\t" (total[w] ? sprintf("%.2f", 100 * up[w] / total[w]) : "")
      print line "\t" since "\t" slowSince
      close(out)
      if (!pruned) system("rm -f \"" out "\"")
    }' "$file"
  [[ -f $file.tmp ]] && mv "$file.tmp" "$file"
done
