#!/usr/bin/env bash
# Usage: [UPTIME_KEEP=$'url\tslow-ms\theader,names\n...'] check.sh URL...
# Prints one tab-separated line per URL: url, status, http code, response ms, cert days left, detail.
# status: ok | down | ssl | skipped. curl verifies the chain and hostname; openssl only reads the expiry date.
# Custom header values come from the keyring (secrets.sh) and reach curl through a file descriptor,
# never argv. With custom headers, redirects are not followed so the headers can't leak to another
# host. If a value can't be read (keyring locked), the check is skipped and not recorded.
# Each result is appended to the URL's history file (see history.sh). Afterwards one line per URL in
# UPTIME_KEEP (or the arguments) gives uptime and when the current outage / slow streak began:
#   stats, url, 24h %, 7d %, 30d %, down-since epoch, slow-since epoch (empty when not ongoing), 3h %
# A check is slow when it is up and slower than the URL's slow-ms from UPTIME_KEEP.
# History files for URLs missing from UPTIME_KEEP (removed entries) are deleted once untouched for
# 10 minutes, so a rename in flight (rename.sh) or a check started before a config change can't
# lose history.

source "$(dirname "$0")/history.sh"
enter_history_dir || exit 1
# Remove temporary files left by a run that was killed outright (SIGKILL skips the EXIT trap).
find . -maxdepth 1 -type f -name '.tmp.*' -mmin +10 -delete

declare -A kept slow headers
if [[ -n ${UPTIME_KEEP:-} ]]; then
  urls=()
  while IFS=$'\t' read -r url ms names; do
    [[ -n $url ]] || continue
    (( ${#urls[@]} < max_targets && ${#url} <= max_url_length )) || continue
    urls+=("$url"); slow[$url]=$ms; headers[$url]=$names; kept[$(history_file "$url")]=1
  done <<< "$UPTIME_KEEP"
else
  urls=("${@:1:max_targets}")
fi

check() {
  local url=$1 code secs ms rc days="" detail="" status host port end name value lines="" n=0
  local opts=(-s -o /dev/null -w '%{http_code} %{time_total} %{exitcode} %{errormsg}' --max-time 10)

  for name in ${headers[$url]//,/ }; do
    (( n++ < max_headers )) || break
    if ! value=$(timeout "$keyring_lookup_timeout" secret-tool lookup service exeque.omarchy-http-uptime url "$url" header "$name" 2>/dev/null); then
      printf '%s\t%s\t\t\t\t%s\n' "$url" skipped "Header $name unavailable (keyring locked?)"
      return
    fi
    lines+="$name: $value"$'\n'
  done

  if [[ -n $lines ]]; then
    read -r code secs detail < <(curl "${opts[@]}" -H @<(printf '%s' "$lines") "$url")
  else
    read -r code secs detail < <(curl "${opts[@]}" -L "$url")
  fi
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
    0)
      if [[ $code == 2* ]]; then status=ok
      elif [[ $code == 3* && -n $lines ]]; then status=down; detail="HTTP $code (redirects are not followed with custom headers)"
      else status=down; detail="HTTP $code"
      fi ;;
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

  detail=${detail:0:200}
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$url" "$status" "$code" "$ms" "$days" "$detail"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$([[ $status == ok ]] && echo 1 || echo 0)" "$status" "$code" "$ms" \
    | append_nofollow "$(history_file "$url")" 2>/dev/null
}

# Bounded: at most max_targets URLs of at most max_url_length characters, max_parallel at a time.
n=0
for url in "$@"; do
  (( n++ < max_targets )) || break
  (( ${#url} <= max_url_length )) || continue
  while (( $(jobs -rp | wc -l) >= max_parallel )); do wait -n; done
  check "$url" &
done
wait

if [[ -n ${UPTIME_KEEP:-} ]]; then
  for file in *.tsv; do
    [[ -e $file && -z ${kept[$file]:-} && -n $(find "$file" -mmin +10) ]] && rm -f "$file"
  done
fi

# ponytail: stats rescan each URL's 30-day history every run; fine for a handful of URLs,
# pre-aggregate per hour if files grow past a few MB.
for url in "${urls[@]}"; do
  file=$(history_file "$url")
  [[ -f $file ]] || continue
  # Cap records per file before scanning it.
  if (( $(read_nofollow "$file" 2>/dev/null | wc -l) > max_records )); then
    make_temp cap && read_nofollow "$file" | tail -n "$max_records" > "$cap" && mv -T -- "$cap" "$file"
  fi
  # awk copies the records it keeps to $out and exits 10 when it pruned any, so the file is only
  # replaced when something changed.
  make_temp out || continue
  read_nofollow "$file" 2>/dev/null | awk -F'\t' -v url="$url" -v slow="${slow[$url]:-}" -v now="$(date +%s)" -v out="$out" '
    BEGIN { span[1] = 86400; span[2] = 7 * 86400; span[3] = 30 * 86400; span[4] = 3 * 3600 }
    now - $1 > 30 * 86400 { pruned = 1; next }
    { print > out
      for (w = 1; w <= 4; w++) if (now - $1 <= span[w]) { total[w]++; up[w] += $2 }
      if ($2) since = ""; else if (since == "") since = $1
      if ($2 && slow != "" && $5 != "" && $5 + 0 > slow + 0) { if (slowSince == "") slowSince = $1 } else slowSince = "" }
    END {
      line = "stats\t" url
      for (w = 1; w <= 3; w++) line = line "\t" (total[w] ? sprintf("%.2f", 100 * up[w] / total[w]) : "")
      print line "\t" since "\t" slowSince "\t" (total[4] ? sprintf("%.2f", 100 * up[4] / total[4]) : "")
      exit (pruned ? 10 : 0)
    }'
  if (( PIPESTATUS[1] == 10 )); then mv -T -- "$out" "$file"; else rm -f -- "$out"; fi
done
